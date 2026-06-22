#!/bin/bash
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs uv

function TestReport--JUnit--AddTC () {
    typeset __shOpt="$(shopt -po errexit nounset xtrace pipefail; shopt -p inherit_errexit)"
    trap 'eval "${__shOpt}"; unset __shOpt; trap - RETURN' RETURN
    set -euxo pipefail; shopt -s inherit_errexit
################################################################################
#   Append one JUnit testcase to JUNIT_FILE, creating the file and suite on
#   first reference.
#
#   Usage:
#       eval "$(
#           typeset -a _fURL=()
#           type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
#           "${_fURL[@]}" \
#       https://<urlAuthToRawContent>/<urlPathToRawContents...>\
#       <repoPaths...>/TestReport--JUnit.sh
#       )"; TestReport--JUnit--AddTC JUNIT_FILE REPORT_NAME TS_NAME TC_NAME \
#           TC_EXEC_TIME [-f MSG | -e MSG]
#
#   Args:
#       JUNIT_FILE      Path to write (or update) the JUnit XML report file.
#       REPORT_NAME     Name of the Test Report, i.e. JUnit XML Root Node
#                       `<testsuites name="...">`.
#                       Must match across all AddTC calls for the same
#                       JUNIT_FILE.
#       TS_NAME         Name of the Test Suite (TS), i.e. JUnit XML node
#                       `<testsuite name="...">`.
#       TC_NAME         Name of the Test Case (TC), i.e. JUnit XML node
#                       `<testcase name="...">`.
#       TC_EXEC_TIME    TC duration in seconds (integer or decimal).
#       -f MSG          Mark the TC as failed with the given message.
#       -e MSG          Mark the TC as an error with the given message.
#
#   Notes:
#     - The generated XML has the `<testsuites>` element as the root node.
#     - TC Status:
#         - A TC is considered "failed" if its execution fails to reach the
#           expected outcome.
#         - A TC is considered an "error" if its execution fails due to an
#           issue with the test itself.
#         - A TC without a "failed" or "error" status is marked as "passed".
#     - Suite and test suite counts (tests, failures, errors, time) are updated
#       after every call.
################################################################################
    typeset junitFile="${1:?TestReport--JUnit--AddTC: JUNIT_FILE is required as non-empty string.}"; (($#)) && shift
    typeset rptName="${1?TestReport--JUnit--AddTC: REPORT_NAME is required.}"; (($#)) && shift
    typeset tsName="${1?TestReport--JUnit--AddTC: TS_NAME is required.}"; (($#)) && shift
    typeset tcName="${1:?TestReport--JUnit--AddTC: TC_NAME is required as non-empty string.}"; (($#)) && shift
    typeset tcExecTime="${1:?TestReport--JUnit--AddTC: TC_EXEC_TIME is required as numeric.}"; (($#)) && shift
    typeset tcRes="${1:-}"; (($#)) && shift
    typeset tcMsg="${1:-}"; (($#)) && shift

    [[ "${tcExecTime}" =~ ^[0-9]+(\.[0-9]+)?$ ]]
    case "${tcRes}" in
        (-f)  tcRes=failure;;&
        (-e)  tcRes=error;;&
        (-e|-f)
            [ -n "${tcMsg}" ]
            ;;
        ('')  tcRes= ;;
        (*)
            : "TestReport--JUnit--AddTC: Unrecognized option: ${tcRes}"
            return 1
            ;;
    esac

    typeset -i __pyRC=0
    uv run --with 'junitparser>=3,<4' python3 - \
        "${junitFile}" "${rptName}" "${tsName}" "${tcName}" "${tcExecTime}" "${tcRes}" "${tcMsg}" <<'PYEOF' || __pyRC=$?
"""Append one testcase to a JUnit XML file, creating the file and suite if needed."""

import os
import sys
import tempfile
from junitparser import JUnitXml, TestSuite, TestCase, Failure, Error

if len(sys.argv) != 8:
    sys.stderr.write(
        "Usage: TestReport--JUnit--AddTC JUNIT_FILE REPORT_NAME TS_NAME TC_NAME"
        " TC_EXEC_TIME [-f MSG | -e MSG]\n"
    )
    sys.exit(1)
junitFile, rptName, tsName, tcName, tcExecTime, tcRes, tcMsg = sys.argv[1:8]

try:
    report = JUnitXml.fromfile(junitFile)
except OSError:
    if os.path.exists(junitFile):
        raise
    report = JUnitXml()

if report.name and report.name != rptName:
    sys.stderr.write(
        f"TestReport--JUnit--AddTC: REPORT_NAME mismatch:"
        f" file has '{report.name}', got '{rptName}'\n"
    )
    sys.exit(1)
report.name = rptName

suite = next((s for s in report if s.name == tsName), None)
if suite is None:
    suite = TestSuite(tsName)
    report.add_testsuite(suite)

tc = TestCase(tcName)
try:
    tc.time = float(tcExecTime)
except ValueError:
    sys.stderr.write(
        f"Invalid TC_EXEC_TIME value '{tcExecTime}' for testcase '{tcName}'"
        f" in suite '{tsName}'\n"
    )
    sys.exit(1)

if tcRes == "failure":
    tc.result = [Failure(tcMsg)]
elif tcRes == "error":
    tc.result = [Error(tcMsg)]

suite.add_testcase(tc)
report.update_statistics()
junitDir = os.path.dirname(junitFile) or "."
os.makedirs(junitDir, exist_ok=True)
fd, tmpOut = tempfile.mkstemp(prefix=".junit-", suffix=".xml", dir=junitDir)
os.close(fd)
try:
    report.write(tmpOut, pretty=True)
    os.replace(tmpOut, junitFile)
finally:
    try:
        os.unlink(tmpOut)
    except FileNotFoundError:
        pass
PYEOF
    return "${__pyRC}"
}
