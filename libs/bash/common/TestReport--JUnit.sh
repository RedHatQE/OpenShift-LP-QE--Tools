#!/bin/bash
################################################################################
#   Bootstrap: ensure uv is available, then define TestReport--JUnit functions.
#
#   Usage:
#       eval "$(
#           typeset -a _fURL=()
#           type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
#           "${_fURL[@]}" \
#       https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/TestReport--JUnit.sh
#       )"
#       TestReport--JUnit--AddTS  "my-suite"
#       TestReport--JUnit--AddTC  "my-suite" "my-test-case" 12 [-f "failure msg"]
#       TestReport--JUnit--Write  "junit_output.xml"
#
#   Functions:
#     TestReport--JUnit--AddTS  TS_NAME
#     TestReport--JUnit--AddTC  TS_NAME TC_NAME SECONDS [-e ERROR_STR] [-f FAILURE_STR]
#     TestReport--JUnit--Write  OUT_FILE
#
#   Notes:
#     - SECONDS in TestReport--JUnit--AddTC is always required (integer or
#       decimal).  Suite and testsuites time= attributes are the sum of all TCs.
#     - -e (error) and -f (failure) in TestReport--JUnit--AddTC are mutually
#       exclusive.  A testcase without either is treated as passed.
#     - The generated XML has <testsuites> as the root node (JUnit plural form).
#     - TestSuite and testsuites counts (tests, failures, errors, time) are
#       computed automatically at write time.
#     - TestReport--JUnit--Write resets accumulated state after writing so that
#       subsequent calls start with a clean slate.
#     - Failure and error messages must not contain embedded newlines.
#     - uv is installed on-demand via EnsureReqs if not already in PATH,
#       making this library usable in any container image.
################################################################################

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        "https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh"
)"; EnsureReqs uv

# Internal field separator — ASCII Unit Separator (0x1F), safe in all names and messages.
# -r (readonly) removed — readonly breaks re-sourcing the library a second time.
typeset -g  __TestReport__JUnit__Sep=$'\x1F'
# Accumulates "tsName<sep>tcName<sep>type<sep>msg<sep>time" per testcase (insertion order).
typeset -ga  __TestReport__JUnit__TcList=()

function TestReport--JUnit--AddTS () {
    typeset __shOpt="$(shopt -po errexit nounset xtrace pipefail; shopt -p inherit_errexit)"
    trap 'eval "${__shOpt}"; unset __shOpt; trap - RETURN' RETURN
    set -euxo pipefail; shopt -s inherit_errexit
################################################################################
#   Register a JUnit TestSuite.
#
#   Usage:
#       TestReport--JUnit--AddTS TS_NAME
#
#   Args:
#       TS_NAME  Name of the test suite (maps to <testsuite name="...">).
#
#   Note: Suites are discovered automatically from AddTC calls at Write time.
#   Calling AddTS is optional but documents intent and validates the name.
################################################################################
    typeset tsName="${1:?TestReport--JUnit--AddTS: TS_NAME is required}"; (($#)) && shift

    : "Suite registered: ${tsName}"

    true
}

function TestReport--JUnit--AddTC () {
    typeset __shOpt="$(shopt -po errexit nounset xtrace pipefail; shopt -p inherit_errexit)"
    trap 'eval "${__shOpt}"; unset __shOpt; trap - RETURN' RETURN
    set -euxo pipefail; shopt -s inherit_errexit
################################################################################
#   Add a JUnit TestCase to a TestSuite.
#
#   Usage:
#       TestReport--JUnit--AddTC TS_NAME TC_NAME SECONDS [-e ERROR_STR] [-f FAILURE_STR]
#
#   Args:
#       TS_NAME     Name of the parent test suite.
#       TC_NAME     Name of the test case (maps to <testcase name="...">).
#       SECONDS     Duration of the test case in seconds (integer or decimal).
#                   Sets the time= attribute on <testcase>. The suite and
#                   testsuites time attributes are the sum of all TC times.
#       -f STR      Mark the testcase as failed with the given message.
#       -e STR      Mark the testcase as errored with the given message.
#                   -f and -e are mutually exclusive.
################################################################################
    typeset tsName="${1:?TestReport--JUnit--AddTC: TS_NAME is required}"; (($#)) && shift
    typeset tcName="${1:?TestReport--JUnit--AddTC: TC_NAME is required}"; (($#)) && shift
    typeset tcTime="${1:?TestReport--JUnit--AddTC: SECONDS is required}"; (($#)) && shift
    [[ "${tcTime}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
        echo "TestReport--JUnit--AddTC: SECONDS must be numeric (got '${tcTime}')." >&2
        return 1
    }

    typeset tcType="" tcMsg=""
    while (($#)); do
        case "${1}" in
            (-f)
                [[ -z "${tcType}" ]] || {
                    echo "TestReport--JUnit--AddTC: -e and -f are mutually exclusive." >&2
                    return 1
                }
                tcType="failure"
                tcMsg="${2:?TestReport--JUnit--AddTC: -f requires a message}"; shift 2
                ;;
            (-e)
                [[ -z "${tcType}" ]] || {
                    echo "TestReport--JUnit--AddTC: -e and -f are mutually exclusive." >&2
                    return 1
                }
                tcType="error"
                tcMsg="${2:?TestReport--JUnit--AddTC: -e requires a message}"; shift 2
                ;;
            (*)
                echo "TestReport--JUnit--AddTC: Unrecognized option '${1}'." >&2
                return 1
                ;;
        esac
    done

    typeset sep="${__TestReport__JUnit__Sep}"
    __TestReport__JUnit__TcList+=("${tsName}${sep}${tcName}${sep}${tcType}${sep}${tcMsg}${sep}${tcTime}")

    true
}

function TestReport--JUnit--Write () {
    typeset __shOpt="$(shopt -po errexit nounset xtrace pipefail; shopt -p inherit_errexit)"
    typeset tmpData
    tmpData="$(mktemp)"
    trap 'rm -f "${tmpData}"; eval "${__shOpt}"; unset __shOpt tmpData; trap - RETURN' RETURN
    set -euxo pipefail; shopt -s inherit_errexit
################################################################################
#   Generate the JUnit XML file from accumulated AddTS / AddTC calls.
#   Resets accumulated state after writing so subsequent calls start clean.
#
#   Usage:
#       TestReport--JUnit--Write OUT_FILE
#
#   Args:
#       OUT_FILE    Path to write the JUnit XML report.
#                   Parent directory must exist.
#
#   Produces a <testsuites> root node containing one <testsuite> per TS_NAME,
#   with correct tests / failures / errors / time counts on both levels.
################################################################################
    typeset outFile="${1:?TestReport--JUnit--Write: OUT_FILE is required}"; (($#)) && shift

    # Write accumulated 0x1F-delimited entries directly to temp file.
    # Each entry already uses 0x1F as field separator — no re-serialisation needed.
    # Handle empty list explicitly to avoid the phantom entry from "${array[@]:-}".
    if (( ${#__TestReport__JUnit__TcList[@]} == 0 )); then
        : > "${tmpData}"
    else
        printf '%s\n' "${__TestReport__JUnit__TcList[@]}" > "${tmpData}"
    fi

    uv run --with 'junitparser>=3,<4' python3 - "${tmpData}" "${outFile}" <<'PYEOF'
"""Generate a JUnit XML report from 0x1F-delimited input using junitparser."""
import sys
from junitparser import JUnitXml, TestSuite, TestCase, Failure, Error

data_file, out_file = sys.argv[1], sys.argv[2]

suites = {}   # Ordered dict (Python 3.7+): suite name -> TestSuite

with open(data_file) as fh:
    for raw in fh:
        line = raw.rstrip('\r\n')   # strip both \r and \n for cross-platform safety.
        if not line:
            continue
        #validate field count before unpacking to produce a clear error on corruption.
        parts = line.split('\x1f', 4)
        if len(parts) != 5:
            sys.stderr.write(
                f"Malformed entry (expected 5 fields, got {len(parts)}): {line!r}\n"
            )
            sys.exit(1)
        ts_name, tc_name, tc_type, tc_msg, tc_time = parts

        if ts_name not in suites:
            suites[ts_name] = TestSuite(ts_name)

        tc = TestCase(tc_name)
        try:
            tc.time = float(tc_time) if tc_time else 0.0
        except ValueError:
            sys.stderr.write(f"Invalid time value '{tc_time}' for testcase '{tc_name}'\n")
            sys.exit(1)
        if tc_type == 'failure':
            tc.result = [Failure(tc_msg)]
        elif tc_type == 'error':
            tc.result = [Error(tc_msg)]

        suites[ts_name].add_testcase(tc)

xml = JUnitXml()
for suite in suites.values():
    suite.update_statistics()
    xml.add_testsuite(suite)
xml.update_statistics()
xml.write(out_file, pretty=True)
PYEOF

    # Reset state so a second Write() call starts with a clean slate.
    __TestReport__JUnit__TcList=()

    true
}
