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
#       TestReport--JUnit--AddTC  "my-suite" "my-test-case" [-f "failure msg"]
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
#     - uv is installed on-demand via EnsureReqs if not already in PATH,
#       making this library usable in any container image.
################################################################################

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        "https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh"
)"; EnsureReqs uv

# Internal field separator — ASCII Unit Separator (0x1F), safe in names.
typeset -gr  __TestReport__JUnit__Sep=$'\x1F'
# Accumulates "tsName<sep>tcName<sep>type<sep>msg" per testcase (insertion order).
typeset -ga  __TestReport__JUnit__TcList=()
# Tracks which suite names have been registered (associative set).
typeset -gA  __TestReport__JUnit__Suites=()

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
################################################################################
    typeset tsName="${1:?TestReport--JUnit--AddTS: TS_NAME is required}"; (($#)) && shift

    __TestReport__JUnit__Suites["${tsName}"]=1

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
#       TS_NAME     Name of the parent test suite (auto-registered if not added
#                   via TestReport--JUnit--AddTS first).
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
            (*) shift ;;
        esac
    done

    # Auto-register the suite if caller skipped TestReport--JUnit--AddTS.
    __TestReport__JUnit__Suites["${tsName}"]=1

    typeset sep="${__TestReport__JUnit__Sep}"
    __TestReport__JUnit__TcList+=("${tsName}${sep}${tcName}${sep}${tcType}${sep}${tcMsg}${sep}${tcTime}")

    true
}

function TestReport--JUnit--Write () {
    typeset __shOpt="$(shopt -po errexit nounset xtrace pipefail; shopt -p inherit_errexit)"
    typeset tmpData="$(mktemp)"
    trap 'rm -f "${tmpData}"; eval "${__shOpt}"; unset __shOpt tmpData; trap - RETURN' RETURN
    set -euxo pipefail; shopt -s inherit_errexit
################################################################################
#   Generate the JUnit XML file from accumulated AddTS / AddTC calls.
#
#   Usage:
#       TestReport--JUnit--Write OUT_FILE
#
#   Args:
#       OUT_FILE    Path to write the JUnit XML report.
#                   Parent directory must exist.
#
#   Produces a <testsuites> root node containing one <testsuite> per TS_NAME,
#   with correct tests / failures / errors counts on both levels.
################################################################################
    typeset outFile="${1:?TestReport--JUnit--Write: OUT_FILE is required}"; (($#)) && shift

    # Serialise accumulated testcase data to a TSV temp file.
    # Format per line: tsName <TAB> tcName <TAB> type <TAB> msg <TAB> time
    typeset entry tsName tcName tcType tcMsg tcTime
    typeset sep="${__TestReport__JUnit__Sep}"
    for entry in "${__TestReport__JUnit__TcList[@]:-}"; do
        IFS="${sep}" read -r tsName tcName tcType tcMsg tcTime <<< "${entry}"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${tsName}" "${tcName}" "${tcType}" "${tcMsg}" "${tcTime}"
    done > "${tmpData}"

    uv run --with junitparser python3 - "${tmpData}" "${outFile}" <<'PYEOF'
import sys
from junitparser import JUnitXml, TestSuite, TestCase, Failure, Error

data_file, out_file = sys.argv[1], sys.argv[2]

suites = {}   # Ordered dict (Python 3.7+): suite name -> TestSuite

with open(data_file) as fh:
    for raw in fh:
        line = raw.rstrip('\n')
        if not line:
            continue
        parts = line.split('\t', 4)
        ts_name = parts[0]
        tc_name = parts[1] if len(parts) > 1 else ''
        tc_type = parts[2] if len(parts) > 2 else ''
        tc_msg  = parts[3] if len(parts) > 3 else ''
        tc_time = parts[4] if len(parts) > 4 else '0'

        if ts_name not in suites:
            suites[ts_name] = TestSuite(ts_name)

        tc = TestCase(tc_name)
        tc.time = float(tc_time) if tc_time else 0.0
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

    true
}
