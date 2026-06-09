#!/bin/bash
#   Bootstrap: ensure uv is available, then define TestReport--JUnit--AddTC.
#
#   Usage:
#       eval "$(
#           typeset -a _fURL=()
#           type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
#           "${_fURL[@]}" \
#               https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/\
#               refs/heads/main/libs/bash/common/TestReport--JUnit.sh
#       )"
#       TestReport--JUnit--AddTC OUT_FILE TS_NAME TC_NAME SECONDS \
#           [-f FAILURE_MSG] [-e ERROR_MSG]

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs uv

function TestReport--JUnit--AddTC () {
################################################################################
#   Append one JUnit testcase to OUT_FILE, creating the file and suite on first
#   reference.  OUT_FILE is always in valid, parseable XML state after each call.
#
#   Usage:
#       TestReport--JUnit--AddTC OUT_FILE TS_NAME TC_NAME SECONDS \
#           [-f FAILURE_MSG] [-e ERROR_MSG]
#
#   Args:
#       OUT_FILE    Path to write (or update) the JUnit XML report.
#                   Parent directory must exist.  Created on first call.
#       TS_NAME     Name of the test suite (<testsuite name="...">).
#                   Created automatically on first reference.
#       TC_NAME     Name of the test case (<testcase name="...">).
#       SECONDS     Duration in seconds (integer or decimal).
#       -f MSG      Mark the testcase as failed with the given message.
#       -e MSG      Mark the testcase as errored with the given message.
#                   -f and -e are mutually exclusive.
#                   Omitting both marks the testcase as passed.
#
#   Notes:
#     - The generated XML has <testsuites> as the root node (JUnit plural form).
#     - Suite and testsuites counts (tests, failures, errors, time) are updated
#       after every call.
#     - uv is installed on-demand via EnsureReqs if not already in PATH.
################################################################################
    typeset __shOpt
    __shOpt="$(shopt -po errexit nounset xtrace pipefail; shopt -p inherit_errexit)"
    trap 'eval "${__shOpt}"; unset __shOpt; trap - RETURN' RETURN
    set -euxo pipefail; shopt -s inherit_errexit

    typeset outFile="${1:?TestReport--JUnit--AddTC: OUT_FILE is required}"; (($#)) && shift
    typeset tsName="${1:?TestReport--JUnit--AddTC: TS_NAME is required}";  (($#)) && shift
    typeset tcName="${1:?TestReport--JUnit--AddTC: TC_NAME is required}";  (($#)) && shift
    typeset tcTime="${1:?TestReport--JUnit--AddTC: SECONDS is required}";  (($#)) && shift
    [[ "${tcTime}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
        echo "TestReport--JUnit--AddTC: SECONDS must be numeric (got '${tcTime}')." >&2
        return 1
    }

    typeset tcResult="" tcMsg=""
    while (($#)); do
        case "${1}" in
            (-f)
                [[ -z "${tcResult}" ]] || {
                    echo "TestReport--JUnit--AddTC: -e and -f are mutually exclusive." >&2
                    return 1
                }
                tcResult="failure"
                tcMsg="${2:?TestReport--JUnit--AddTC: -f requires a message}"; shift 2
                ;;
            (-e)
                [[ -z "${tcResult}" ]] || {
                    echo "TestReport--JUnit--AddTC: -e and -f are mutually exclusive." >&2
                    return 1
                }
                tcResult="error"
                tcMsg="${2:?TestReport--JUnit--AddTC: -e requires a message}"; shift 2
                ;;
            (*)
                echo "TestReport--JUnit--AddTC: Unrecognized option '${1}'." >&2
                return 1
                ;;
        esac
    done

    uv run --with 'junitparser>=3,<4' python3 - \
        "${outFile}" "${tsName}" "${tcName}" "${tcTime}" "${tcResult}" "${tcMsg}" <<'PYEOF'
"""Append one testcase to a JUnit XML file, creating the file and suite if needed."""
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from junitparser import JUnitXml, TestSuite, TestCase, Failure, Error

if len(sys.argv) != 7:
    sys.stderr.write(f"Internal error: expected 6 arguments, got {len(sys.argv) - 1}\n")
    sys.exit(1)
out_file, ts_name, tc_name, tc_time, tc_result, tc_msg = sys.argv[1:7]

try:
    report = JUnitXml.fromfile(out_file)
except (FileNotFoundError, ET.ParseError):
    report = JUnitXml()

suite = next((s for s in report if s.name == ts_name), None)
if suite is None:
    suite = TestSuite(ts_name)
    report.add_testsuite(suite)

tc = TestCase(tc_name)
try:
    tc.time = float(tc_time)
except ValueError:
    sys.stderr.write(f"Invalid time value '{tc_time}' for testcase '{tc_name}' in suite '{ts_name}'\n")
    sys.exit(1)
if tc_result == 'failure':
    tc.result = [Failure(tc_msg)]
elif tc_result == 'error':
    tc.result = [Error(tc_msg)]

suite.add_testcase(tc)
suite.update_statistics()
report.update_statistics()
fd, tmp_out = tempfile.mkstemp(
    prefix=".junit-", suffix=".xml", dir=os.path.dirname(out_file) or "."
)
os.close(fd)
try:
    report.write(tmp_out, pretty=True)
    os.replace(tmp_out, out_file)
finally:
    try:
        os.unlink(tmp_out)
    except FileNotFoundError:
        pass
PYEOF

    true
}
