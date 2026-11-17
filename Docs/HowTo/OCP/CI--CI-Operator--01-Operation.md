# CI -- CI Operator -- Operation
## References
<details><summary>CI Operator Documentation</summary>

[CI Operator](https://docs.ci.openshift.org/)
</details>


## Operations
### Tips & Tricks
#### CI Operator Emulator
<details><summary>Overview</summary>

CI Operator emulator script for testing OpenShift CI Operator `Step` locally, by emulating the CI Operator Pod environment as per Step-Registry configuration.
</details>
<details><summary>Architecture</summary>
<details><summary>Details</summary>

 1. **Clones a CI Operator fork repository** from a specified Git source.
 2. **Generates Test CI Configurations**:
    1. **The Pre-Test CI Configuration** by:
          - Copying CI Configuration file (`_CI__CI_CFG`) and parsing in only the target Job configuration (`_CI__TEST_NAME`).
          - Tracing target Step through the target Job configuration (`.tests[]`) and building a Pre-Test Job executing previous Steps of the target Step.
    2. **The Image Retrieval CI Configuration** by:
          - Parsing Step-Registry Configuration file (`_CI__STEP_CFG`).
          - Tracing image dependency chains through the CI Configuration.
 3. **Creates helper functions** that are exported to the shell:
      - `ci--sync--tst-env`: Synchronizes CI Test Env. to local, e.g. retrieve the test credentials from the executing Stub Step Pod, copy the used `oc` binary
        configured in the target Step, copy the content of `${SHARED_DIR}`, etc. This prepares the Test Env. to mimic the target Step environment.
      - `ci--wait--test`: Control the execution of the Stub Step.
      - `ci--pull--ctr-img`: Pulls target Step Container Image from the CI Build Cluster.
      - `ci--start--ctr`: Starts a Test Container to emulate the CI test environment.
</details>
<details><summary>Directory Structures</summary>

The script creates this directory hierarchy:
```
${hstRootDir}/  - Top Root directory.
 |- cfg/        - Configuration directory.
 |   |- env--ctr                        - File holding user definition of Env. Var.s inside Test Container.
 |- src/        - Cloned CI Operator fork repository.
 |- fs-root/    - Container's File System root (mapped to `/` inside Test Container).
 |   |- ws-shr/                         - WorkSpace accessible from both Host and Test Container.
 |   |   |- bin/                        - Binaries copied into Test Container (`oc`, `tkn`, `virtctl`, etc.).
 |   |   |- etc/                        - Configuration files.
 |   |   |- step/                       - Step Script directory. Place-holder for Test Container FS bind-mount.
 |   |   |- ci-op--bld-cluster/         - CI Operator Build Cluster `KUBECONFIG` and target Step Container Image specification.
 |   |   |- ci                          - Symbolic Link pointing to the current run directory below.
 |   |   |- ci--<YYYYMMDD>T<HHMMSS>Z/   - Time-stamped run directories.
 |   |   |   |- artifacts/              - Test Artifacts output (`${ARTIFACT_DIR}`).
 |   |   |- cluster-profile/            - Cluster Profile directory (`${CLUSTER_PROFILE_DIR}`).
 |   |   |- shared/                     - Shared directory for test data (`${SHARED_DIR}`).
 |   |   |- tmp/                        - Temporary directory, to hold copy of some unmodifiable files.
 |   |   |- env--ctr                    - File holding definition of Env. Var.s inside Test Container.
 |   |- ...                             - Directories holding target Step Secrets.
 |- artifacts/  - Root directory for all previous run's Test Artifacts.
 |- ws-own/     - Tool internal WorkSpace.
```
</details>
<details><summary>Target Step Tracing</summary>

The script includes logic to locate target Step in the target Job's Step sequence:
  - Build truncated `.tests[].steps` Step sequence, preserving untouched Chains.
  - Scan the sequence in order (`.pre`, `.test`, `.post`), stop before the target Step.
  - Chains not containing the target Step are kept as Chain references.
  - Chains containing the target Step are unpacked recursively.
</details>
<details><summary>Image Chain Tracing</summary>

The script includes logic to trace target Step Container Image dependencies:
  - Recursively follows `from` references in CI Configurations.
  - Supports CI Configuration source references: `base_images`, `base_rpm_images`, and `external_images`.
  - Handles special Container Image Tags: `root`, `src`, `bin`, `test-bin`.
  - Generates minimal CI Configurations containing only required target Step Container Image build steps, so it can be pulled to local system.
  - The Step Script directory from git Working Tree (`${hstRootDir}/src/...`) is bind-mounted R/O to Test Container FS at `/ws/step`.
    Modifications to the script in the git Working Tree are immediately visible inside the running Container.
    The Container cannot modify the Step Script (R/O mount for safety).
</details>
</details>
<details><summary>Scripts</summary>
<details><summary>Optional Custom Image Retrieval Script</summary>

```shell
{
    _CI__IMG_RETR__TST_SCR="${_CI__IMG_RETR__TST_SCR:+${_CI__IMG_RETR__TST_SCR}$'\n'}"$'{\n'"$(
        cat - 0<<'evalEOF';
    imgRetrTstScr="${imgRetrTstScr:+${imgRetrTstScr}$'\n'}"$'(\n'"$(
        cat - 0<<'scrEOF';
: 'Example of custom Image Retrieval Test Script.'
ps faux
pwd
ls -laF
ls -laF "${SHARED_DIR}/"
ls -laF "${CLUSTER_PROFILE_DIR}/"
type oc; which oc
e=180; while ((e--)); do { [ -e /tmp/test.done ] && break; sleep 60; }; done
scrEOF
    )"$'\n)'
evalEOF
    )"$'\n}'
}
```
</details>
<details><summary>Secret Retrieval</summary>

```shell
{   # Secret Retrieval.
    _CI__IMG_RETR__TST_SCR="${_CI__IMG_RETR__TST_SCR:+${_CI__IMG_RETR__TST_SCR}$'\n'}"$'{\n'"$(
        cat - 0<<'evalEOF';
    imgRetrTstScr="${imgRetrTstScr:+${imgRetrTstScr}$'\n'}"$'(\n'"$(
        cat - 0<<scrEOF; cat - 0<<'scrEOF';
: 'Retrieving the required secrets.'
typeset -a sp=(${secretPaths[@]@Q})
scrEOF
[ -n "${CLUSTER_PROFILE_DIR}" ] && sp+=("${CLUSTER_PROFILE_DIR}")
pwd
ps faux
ls -laF ./
((${#sp[@]})) && {
    if type -t zip 2> /dev/null; then
        zip -r "${ARTIFACT_DIR}/data.zip" "${sp[@]}" -x '..*'
    elif type -t tar 2> /dev/null; then
        if type -t base64 2> /dev/null; then
            tar zhc --exclude '..*' "${sp[@]}" |
                base64 1> "${ARTIFACT_DIR}/data.b64"
        else
            tar zhcf /tmp/data.tgz --exclude '..*' "${sp[@]}" &&
                tar zcf "${ARTIFACT_DIR}/data.tgz" /tmp/data.tgz
            rm -f /tmp/data.tgz
        fi
    fi
}
ls -laF "${ARTIFACT_DIR}/"
e=90; while ((e--)); do { [ -e /tmp/debug.done ] && break; sleep 60; }; done
scrEOF
    )"$'\n)'
evalEOF
    )"$'\n}'
}
```
</details>
<details><summary>Main Script</summary>

```shell
__SHELL=0 \
    _CI__STEP_CFG='...stepRefConfYAMLfileRelFromRepoRoot...' \
    _CI__TEST_NAME='...testNameInCIconfYAMLfile...' \
    _CI__CI_CFG='...ciConfYAMLfileRelFromRepoRoot...' \
    _CI__SRC_GIT='...gitCloneURL_CIoperatorForkRepo...|...forkRepoBranch...' \
    _CI__CLS_PRF__DEV='...clusterProfileNameForDev...' \
    _CI__AS_USR="${_CI__AS_USR:-1000}" \
    _CI__IMG_RETR__TST_SCR="${_CI__IMG_RETR__TST_SCR:-}" \
    _CI__HST_ROOT_DIR="${_CI__HST_ROOT_DIR:-${PWD}}" \
    _CI__CTR_SHELL="${_CI__CTR_SHELL:-/bin/bash}" \
    K8S__CLUSTER_DIR="${K8S__CLUSTER_DIR:-cfg/ocp}" \
    KUBECONFIG="${KUBECONFIG:-${K8S__CLUSTER_DIR}/auth/kubeconfig}" \
    KUBEADMIN_PASSWORD_FILE="${KUBEADMIN_PASSWORD_FILE:-${K8S__CLUSTER_DIR}/auth/kubeadmin-password}" \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        [ -n "${K8S__CLUSTER_DIR}" ] || [ -n "${KUBECONFIG}" ] || {
            cat - 0<<'txtEOF'
**********
REQUIRED: Set at least one of the following:
  - Env. Var. `K8S__CLUSTER_DIR` to the valid installation directory of the CUT
    (Cluster Under Test) or an empty directory if CUT is not yet available.
  - Env. Var. `KUBECONFIG` to the valid configuration file that point to the
    CUT.
**********
txtEOF
            exit 1
        }
        [ -e "${KUBECONFIG}" ] || cat - 0<<txtEOF
**********
WARNING!!! The Env. Var. \`KUBECONFIG\` point to non-existing file:
    ${KUBECONFIG}
**********
txtEOF
        [ -e "${KUBEADMIN_PASSWORD_FILE}" ] || cat - 0<<txtEOF
**********
WARNING!!! The Env. Var. \`KUBEADMIN_PASSWORD_FILE\` point to non-existing file:
    ${KUBEADMIN_PASSWORD_FILE}
**********
txtEOF
        ((__SHELL)) && PROMPT_COMMAND='PS1="${PS1%\[DEBUG\] }[DEBUG] "' exec "${SHELL}" # Do NOT forget to exit this `DEBUG` session!!!

        typeset stepCfg="${_CI__STEP_CFG}"
        typeset testName="${_CI__TEST_NAME}"
        typeset ciCfg="${_CI__CI_CFG}"
        typeset srcGit="${_CI__SRC_GIT}"
        typeset clsPrfDev="${_CI__CLS_PRF__DEV}"
        typeset asUsr="${_CI__AS_USR}"
        typeset imgRetrTstScr="${_CI__IMG_RETR__TST_SCR}"
        typeset hstRootDir="${_CI__HST_ROOT_DIR}"; mkdir -p "${hstRootDir}"
        typeset hstCfgDir="${hstRootDir}/cfg"; mkdir -p "${hstCfgDir}"
        typeset hstSrcDir="${hstRootDir}/src"
        typeset hstCtrFSrootDir="${hstRootDir}/fs-root"; mkdir -p "${hstCtrFSrootDir}"
        typeset hstArtRootDir="${hstRootDir}/artifacts"; mkdir -p "${hstArtRootDir}"
        typeset hstWSdir="${hstRootDir}/ws-own"; mkdir -p "${hstWSdir}"
        typeset ctrShell="${_CI__CTR_SHELL}"
        typeset ctrWSdir=/ws-shr
        typeset ctrWSbinDir="${ctrWSdir}/bin"; mkdir -p "${hstCtrFSrootDir}${ctrWSbinDir}"
        typeset ctrWSetcDir="${ctrWSdir}/etc"; mkdir -p "${hstCtrFSrootDir}${ctrWSetcDir}"
        typeset ctrWStmpDir="${ctrWSdir}/tmp"; mkdir -p "${hstCtrFSrootDir}${ctrWStmpDir}"
        typeset ctrCIbldClsDir="${ctrWSdir}/ci-op--bld-cluster"; mkdir -p "${hstCtrFSrootDir}${ctrCIbldClsDir}"
        typeset ctrCIbldCls_Kcfg="${ctrCIbldClsDir}/kubeconfig--${ctrCIbldClsDir##*/}"
        typeset ctrCIbldCls_ImgSpecInfo="${ctrCIbldClsDir}/ctrImgSpec"
        typeset ctrCIenvUsr="${hstCfgDir}/env--ctr"; 1>> "${ctrCIenvUsr}"
        typeset testJobName="${ciCfg##*/}"; testJobName="${testJobName/__/-}"; testJobName="${testJobName%.*}"
        typeset stepName=
        typeset preTestCIcfg="${ciCfg##*/}"; preTestCIcfg="${hstSrcDir}/${ciCfg%/*}/${preTestCIcfg%%__*}__ciOpEmul--preTest.yaml"
        typeset preTestJobName="${preTestCIcfg##*/}"; preTestJobName="${preTestJobName/__/-}"; preTestJobName="${preTestJobName%.*}"
        typeset imgRetrCIcfg="${ciCfg##*/}"; imgRetrCIcfg="${hstSrcDir}/${ciCfg%/*}/${imgRetrCIcfg%%__*}__ciOpEmul--imgRetr.yaml"
        typeset imgRetrJobName="${imgRetrCIcfg##*/}"; imgRetrJobName="${imgRetrJobName/__/-}"; imgRetrJobName="${imgRetrJobName%.*}"
        typeset e=
        typeset -a secretPaths=()
        unset -v ${!_CI__*}

        # Fixed Container Env. Var.s.
        typeset ctrCPdir="${ctrWSdir}/cluster-profile"
        typeset ctrSharedDir="${ctrWSdir}/shared"
        typeset -A ctrEnvVars=(
            [CLUSTER_PROFILE_DIR]="${ctrCPdir@Q}"
            [SHARED_DIR]="${ctrSharedDir@Q}"
            [KUBECONFIG]='"${CLUSTER_PROFILE_DIR}/kubeconfig"'
            [KUBECONFIGMINIMAL]='"${CLUSTER_PROFILE_DIR}/kubeconfig-minimal"'
            [KUBEADMIN_PASSWORD_FILE]='"${CLUSTER_PROFILE_DIR}/kubeadmin-password"'
        )

        function ciEmulOp--Lgn2BuildCls () {
            typeset jobDesc="${1:?}"; (($#)) && shift
            typeset jobName="${1:?}"; (($#)) && shift
            typeset outerTask="${1:?}"; (($#)) && shift

            # Ensure the appropriate Job is running.
            printf '%s\n    %s\n%s' \
                "Make sure the ${jobDesc} Job is running:" \
                "(\`/pj-rehearse ${jobName}\`)?" \
                'Press any key to continue or `Ctrl-C` to cancel...'
            read -srN 1 && echo

            # Check authentication.
            while { ! { oc whoami && oc project; }; } 1> /dev/null 2>&1; do
                cat - 0<<txtEOF; cat - 0<<'txtEOF'; cat - 0<<txtEOF
----------------------------------------
Please login to the executing CI Operator Build Server's Web Console
(Job \`${jobName}\`)
txtEOF
and get the CLI Login Command, `oc login ...`.
Preferably, also set the Context to the NameSpace the above Job is running:
    oc project <rehearsedJobNS>
Exit this Interactive Session, when the login is successfully completed, to
txtEOF
continue (Exit Status 255 will cancel the ${outerTask} attempt).
----------------------------------------
txtEOF
                PROMPT_COMMAND='PS1="${PS1%\[CI Operator Build Cluster Login\] }'\
'[CI Operator Build Cluster Login] "' "${SHELL}" || (($? != 255)) || return 1
            done
        }; export -f ciEmulOp--Lgn2BuildCls

        function ciEmulOp--GetJobNS () {
            typeset -i prNum="${1:?}"; (($#)) && shift
            typeset jobName="${1:?}"; (($#)) && shift
            typeset jobRun="rehearse-${prNum}-${jobName}"
            typeset jobInfo="$(
                curl -fsSL 'https://prow.ci.openshift.org/prowjobs.js' |
                jq -cr \
                    --arg j "${jobRun}" \
                    --argjson pr "${prNum}" \
                    '
                        [
                            .items[]? | select(
                                (.spec | (
                                    (.job == $j) and
                                    any(.refs.pulls[]?; .number == $pr)
                                )) and
                                (.status | (
                                    (.state == "pending") and
                                    (.url != null)
                                ))
                            ) | {
                                id: (.status.build_id // empty),
                                time: .metadata.creationTimestamp,
                                url: (.status.url // empty)
                            }
                        ] |
                        (sort_by(.time)[-1] // empty)
                    '
            )"; [ -n "${jobInfo}" ] || {
                echo \
"The Job \`${jobName}\` is not being rehearsed in "\
"[PR #${prNum}](https://github.com/openshift/release/pull/${prNum})."\
                    1>&2
                return 1
            }
            typeset jobNS="$(
                curl -fsSL \
                    "https://prow.ci.openshift.org/log?container=test&id=$(
                        jq -cr '.id' 0<<<"${jobInfo}"
                    )&job=${jobRun}" |
                sed -nE '/^[^\s]+\s+Using namespace /{s|^.+/(\S+).*|\1|p;q}'
            )"; [ -n "${jobNS}" ] || {
                echo \
                    "The Job \`${jobName}\` may not have progressed to where"\
                    'its NameSpace has been created yet.'\
                    1>&2
                return 1
            }
            echo "${jobNS}"
            true
        }; export -f ciEmulOp--GetJobNS

        function ciEmulOp--Wait4Step () {
            typeset -i prNum="${1:?}"; (($#)) && shift
            typeset jobNS="${1:?}"; (($#)) && shift
            typeset jobRun="rehearse-${prNum}-${1:?}"; (($#)) && shift
            typeset stepName="${1:?}"; (($#)) && shift
            typeset wInt= wMax=
            ((${#jobRun} > 63)) && jobRun="${jobRun:0:60}xxx"
            (   # Isolate `SECONDS` reset.
                # Waiting for target Step to be ready.
                typeset err=
                SECONDS=0 wInt=300 wMax=86400   # 24 H Max.
                while ((SECONDS < wMax)); do
                    err="$(oc -n "${jobNS}" wait Pods \
                        -l \
"ci.openshift.io/jobname=${jobRun},"\
"ci.openshift.io/metadata.step=${stepName}"\
                        --for create \
                        --timeout ${wInt}s \
                    2>&1 1> /dev/null)" && break
                    [[ "${err}" =~ ^'error: timed out' ]] || {
                        echo "${err}" 1>&2
                        exit 1
                    }
                    echo "Waited ${SECONDS}/${wMax} sec.: "\
"Executing prior Steps... [$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Current Step: $(
    oc -n "${jobNS}" get Pods \
        -l "ci.openshift.io/jobname=${jobRun}" \
        --field-selector 'status.phase!=Succeeded,status.phase!=Failed' \
        -o jsonpath-as-json=\
'{.items[*].metadata.labels.ci\.openshift\.io/metadata\.step}' |
    jq -r '.[0] // "N/A"'
)" 1>&2
                done
                ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'target Step to be ready.' 1>&2; exit 2; }
                true
            )
            (   # Isolate `SECONDS` reset.
                # Waiting for target Step to run.
                typeset err=
                SECONDS=0 wInt=30 wMax=900      # 15 Min. Max.
                while ((SECONDS < wMax)); do
                    err="$(oc -n "${jobNS}" wait Pods \
                        -l \
"ci.openshift.io/jobname=${jobRun},"\
"ci.openshift.io/metadata.step=${stepName}"\
                        --for condition=Ready \
                        --timeout ${wInt}s \
                    2>&1 1> /dev/null)" && break
                    [[ "${err}" =~ ^'error: timed out' ]] || {
                        echo "${err}" 1>&2
                        exit 1
                    }
                    echo "Waited ${SECONDS}/${wMax} sec.: "\
'Preparing Step...' 1>&2
                done
                ((SECONDS >= wMax)) && { echo 'Timed out waiting for '\
'target Step to run.' 1>&2; exit 2; }
                true
            )
            true
        }; export -f ciEmulOp--Wait4Step

        # Shallow Clone the CI Operator Fork Repo.
        [ -e "${hstSrcDir}/" ] ||
            git clone --depth 1 --single-branch --no-tags \
                --branch "${srcGit#*|}" "${srcGit%|*}" "${hstSrcDir}/"
        # Prepare the Host directory that serve as Container Root FS.
        setfacl -R -m g::rwx,m::rwx,d:g::rwx,d:m::rwx "${hstCtrFSrootDir}/"

        # Get Secret's Mount Points.
        eval "secretPaths=($({
            yq -o json eval '.ref.credentials' "${hstSrcDir}/${stepCfg}" |
            jq -r '(. // []) | .[].mount_path | @sh'
        } || echo "\$(false)"))"
        # Prepare directory structure of Container Root FS.
        for e in "${secretPaths[@]}"; do
            mkdir -p "${hstCtrFSrootDir}${e}"
        done
        # Create Login Script (MUST be POSIX compliant).
        cat - 0<<'scrEOF' 1> "${hstCtrFSrootDir}${ctrWSetcDir}/bash.bash.login"
find "${WS__TMP}/" "${SHARED_DIR}/" \
    -mindepth 1 -maxdepth 1 \
    -exec bash -c '
        chown -R "$(id -u):$(id -g)" "${1}" 2> /dev/null
    ' '' '{}' \;
# Change `KUBECONFIG` to point to the R/W version.
export KUBECONFIG="${WS__TMP}/${KUBECONFIG#${WS__ROOT}/}"
scrEOF
        # Create Logout Script (MUST be POSIX compliant).
        cat - 0<<'scrEOF' 1> "${hstCtrFSrootDir}${ctrWSetcDir}/bash.bash.logout"
echo 'Running logout script. Please wait...'
chown -R 0:0 "${WS__ROOT}/" 2> /dev/null || true
scrEOF

        # Construct Test Job Name and Step Name.
        testJobName="rehearse-ci-${testJobName}-${testName}"
        stepName="$(yq eval '.ref.as' "${hstSrcDir}/${stepCfg}")"

        # Generate Pre-Test CI Configuration file.
        (
            typeset stepRegRoot="${hstSrcDir}/${stepCfg%%/step-registry/*}/step-registry"
            typeset wfName= wfYAML= yamlFile= yamlPath= phase= truncSteps=
            typeset -i stepFnd=0 huntStepPhase=0

            {
                yq -o json eval . |
                jq -c --arg testName "${testName}" '
                    del(.zz_generated_metadata) |
                    .tests=([.tests[] | select(.as == $testName)] | (
                        if (length == 0) then error("No Match.") end
                    )) |
                    .tests[0]|=(
                        del(.cron, .interval) |
                        .as="run-prior-steps" |
                        .timeout="24h0m0s"
                    )
                ' |
                yq -p json -o yaml eval .
            } 0< "${hstSrcDir}/${ciCfg}" 1> "${preTestCIcfg}" || {
                echo \
                    'Error: Can not find CI Operator Test Conf.'\
                    "\`${testName}\` inside CI Conf. file \`${ciCfg}\`."\
                    1>&2
                false
            }

            # Find a Step-Registry YAML file by name and type
            #   (`ref` / `chain` / `workflow`).
            function FindStepRegYAML () {
                typeset srName="${1:-}"; (($#)) && shift
                typeset srType="${1:?}"; (($#)) && shift
                [ -z "${srName}" ] || {
                    find "${stepRegRoot}/" \
                        -name "${srName}-${srType}.yaml" \
                        -print \
                        -quit |
                    grep .
                }
                true
            }

            function BuildPriorSteps () {
                typeset stepName="${1:?}"; (($#)) && shift
                typeset yFile="${1:?}"; (($#)) && shift
                typeset yPath="${1:?}"; (($#)) && shift

                typeset builtSteps='[]' subSteps=
                typeset refName= chnName= chnYAML=
                typeset -i i=0 fnd=0

                typeset -i totSteps="$(
                    yq eval "${yPath} | length" "${yFile}"
                )"

                while ((i < totSteps)); do
                    subSteps="$(
                        yq -o json -I 0 eval "${yPath}[${i}]" "${yFile}"
                    )"
                    if [ -n "$(jq -c '.as // empty' 0<<<"${subSteps}")" ]; then
                        # Inline Literal Step (can not be the target Step).
                        builtSteps="$(jq -c \
                            --argjson s "${subSteps}" \
                            '. + [$s]' \
                        0<<<"${builtSteps}")"
                    elif {
                        refName="$(jq -r '.ref // empty' 0<<<"${subSteps}")" &&
                        [ -n "${refName}" ]
                    }; then
                        # Step Reference.
                        [ "${refName}" = "${stepName}" ] && fnd=1 && break
                        builtSteps="$(jq -c --arg r "${refName}" '
                            . + [{"ref": $r}]
                        ' 0<<<"${builtSteps}")"
                    else
                        # Chain.
                        chnName="$(
                            jq -r '.chain // empty' 0<<<"${subSteps}"
                        )"
                        chnYAML="$(FindStepRegYAML "${chnName}" chain)"
                        if [ -z "${chnYAML}" ]; then
                            echo \
                                'Error: Can not find CI Operator Chain'\
                                "\`${chnName}\` inside Step-Registry."\
                                1>&2
                            return 2
                        fi
                        subSteps="$(
                            BuildPriorSteps \
                                "${stepName}" "${chnYAML}" '.chain.steps'
                        )" || {
                            [ -z "${subSteps}" ] && return 2
                            # Chain contains target, unpack it.
                            builtSteps="$(yq -o json -I 0 eval '
                                . as $all | $all[0] + $all[1]
                            ' 0<<<"[${builtSteps}, ${subSteps}]")"
                            fnd=1 && break
                        }
                        # Chain does not contain target, keep as-is.
                        builtSteps="$(jq -c --arg c "${chnName}" '
                            . + [{"chain": $c}]
                        ' 0<<<"${builtSteps}")"
                    fi
                    ((++i))
                done
                echo "${builtSteps}"

                ((!fnd))
            }

            # Locate target Step.
            wfName="$(
                yq eval '.tests[0].steps.workflow // ""' "${preTestCIcfg}"
            )"
            wfYAML="$(FindStepRegYAML "${wfName}" workflow)" || {
                echo \
                    'Error: Can not find CI Operator Workflow'\
                    "\`${wfName}\` inside Step-Registry."\
                    1>&2
                false
            }

            while ((!stepFnd)); do
                yamlFile='' phase=''
                case $((huntStepPhase++)) in
                  (0)   phase=pre;;
                  (1)   phase=test;;
                  (2)   phase=post;;
                  (*)   break;;
                esac
                # Inline `.tests[].steps.<pre|test|post>` overrides
                #   `workflow.steps.<pre|test|post>`.
                [ "$(
                    yq eval ".tests[0].steps.${phase} | type" "${preTestCIcfg}"
                )" = '!!seq' ] && {
                    yamlFile="${preTestCIcfg}"
                    yamlPath=".tests[0].steps.${phase}"
                } || { [ -z "${wfYAML}" ] || {
                    yamlFile="${wfYAML}"
                    yamlPath=".workflow.steps.${phase}"
                }; }
                [ -z "${yamlFile}" ] || {
                    truncSteps="$(
                        BuildPriorSteps \
                            "${stepName}" "${yamlFile}" "${yamlPath}"
                    )" || {
                        [ -z "${truncSteps}" ] && false
                        stepFnd=1
                        exec 3< <(0< "${preTestCIcfg}"); wait $!
                        {
                            yq -o json eval . |
                            jq -c \
                                --argjson phase $((huntStepPhase)) \
                                --argjson tSteps "${truncSteps}" \
                                '.tests[0].steps|=(
                                    if ($phase == 1) then (
                                        .pre=$tSteps |
                                        .test=[] |
                                        .post=[]
                                    ) end | if ($phase == 2) then (
                                        .test=$tSteps |
                                        .post=[]
                                    ) end | if ($phase == 3) then (
                                        .post=$tSteps
                                    ) end
                                )' |
                            yq -p json -o yaml eval .
                        } 0<&3 1> "${preTestCIcfg}"
                    }
                }
            done
            ((stepFnd)) || {
                echo \
                    'Error: Can not find CI Operator Step'\
                    "\`${stepName}\` inside Job \`${testName}\`."\
                    1>&2
                false
            }
        )

        # Construct Pre-Test Job Name.
        preTestJobName="pull-ci-${preTestJobName}-$(
            yq eval '.tests[0].as' "${preTestCIcfg}"
        )"

        # Generate Image Retrieval CI Configuration file.
        imgRetrTstScr="$(cat - 0<<'scrEOF'
shopt -op; shopt -p; printenv; set -x
set +eu -o pipefail; shopt -s inherit_errexit
scrEOF
        )${imgRetrTstScr:+$'\n'$(
            e="${imgRetrTstScr}"
            imgRetrTstScr=  # Reset because we need to rebuild it.
            eval "${e}"     # Rebuild to resolve early expansion of variables.
            echo "${imgRetrTstScr}"
        )}"$'\ntrue'
        {
            yq -o json eval . |
            jq -c \
                --argjson step "$(
                    yq -o json -I 0 eval .ref "${hstSrcDir}/${stepCfg}"
                )" \
                --argjson job "$(
                    yq -o json -I 0 eval . "${hstSrcDir}/${ciCfg}"
                )" \
                --arg imgRetrTstScr "${imgRetrTstScr}" \
                "$(cat - 0<<'scrEOF'
##  Functions
def FindImageByTo($toVal):
    ($job.images.items // [])[] | select(.to == $toVal)
;

def TraceImgChain($fromKey):
    # Recursive function to trace the image chain.
    # Returns:
    #   {srcImgPath: [["path", ...], ...], imgChain: [...]}
    #       OR
    #   {error: "msg"}
    (
        if (($fromKey == "root") or ($fromKey == "src")) then
            {srcImgPath: [["build_root"]]}
        elif ($fromKey == "bin") then
            {srcImgPath: [["build_root"], ["binary_build_commands"]]}
        elif ($fromKey == "test-bin") then
            {srcImgPath: [["build_root"], ["test_binary_build_commands"]]}
        elif (($job.base_images // {}) | has($fromKey)) then
            {srcImgPath: [["base_images", $fromKey]]}
        elif (($job.base_rpm_images // {}) | has($fromKey)) then
            {srcImgPath: [["base_rpm_images", $fromKey]]}
        elif (($job.external_images // {}) | has($fromKey)) then
            {srcImgPath: [["external_images", $fromKey]]}
        else null
        end
    ) as $imgSrc |
    if ($imgSrc != null) then
        $imgSrc + {imgChain: []}
    else
        # Find the image whose `.to` matches `.from`.
        (FindImageByTo($fromKey) // null) as $prvImg |
        if ($prvImg == null) then
            [(
                if ($job | has("releases")) then ["releases"]
                else empty end
            ), (
                if ($job | has("tag_specification")) then ["tag_specification"]
                else empty end
            )] as $payloadPaths |
            if (($payloadPaths | length) > 0) then
                {srcImgPath: $payloadPaths, imgChain: []}
            else
                {error: (
                    "Image chain incomplete, " +
                    "cannot find source for `\($fromKey)`."
                )}
            end
        elif ($prvImg | has("from")) then
            # Trace the previous `.images`'s `.from`.
            TraceImgChain($prvImg.from) |
            if .error then .    # Pass the error up.
            else
                # Add the current link to the chain.
                {
                    srcImgPath: .srcImgPath,
                    imgChain: (.imgChain + [$prvImg])
                }
            end
        else {srcImgPath: [], imgChain: [$prvImg]}
        end
    end
;

##  Main
(
    if ($step | has("from")) then
        TraceImgChain($step.from) as $res |
        if $res.error then
            error($res.error)
        else
            reduce $res.srcImgPath[] as $path (
                .;
                setpath($path; ($job | getpath($path)))
            ) |
            if (($res.imgChain | length) > 0) then
                .images.items = $res.imgChain
            end
        end
    end
) |
(
    .tests[0].steps.test[0]|=(
        .commands=$imgRetrTstScr |
        .credentials=($step.credentials // []) |
        if ($step | has("from_image")) then
            .from_image=$step.from_image
        else
            .from=$step.from
        end
    )
) | walk(
    if (type == "object") then
        (to_entries | sort_by(.key) | from_entries)
    end
)
scrEOF
                )" |
            yq -p json -o yaml eval .
        } 0<<'fileEOF' 1>"${imgRetrCIcfg}"
prowgen:
  enable_secrets_store_csi_driver: true
resources:
  '*':
    limits:
      memory: 1Gi
    requests:
      cpu: 100m
      memory: 200Mi
tests:
  - as: img-retr
    steps:
      test:
        - as: ci-op-emul--step--0
          commands: ''
          resources:
            limits:
              memory: 1Gi
            requests:
              cpu: 100m
              memory: 200Mi
          timeout: 24h0m0s
    timeout: 24h0m0s
fileEOF
        imgRetrJobName="pull-ci-${imgRetrJobName}-$(
            yq eval '.tests[0].as' "${imgRetrCIcfg}"
        )"

        # Inject trailing Step (Stub Step) to keep the Pod alive.
        #   This allows `ci--sync--tst-env` to sync. the CI Test Env. to local,
        #   such as retrieving the Test Credentials and the `${SHARED_DIR}`
        #   content from the executing Pod, etc.
        # Inject no-op Step to override `workflow` phases.
        exec 3< <(0< "${preTestCIcfg}"); wait $!
        {
            yq -o json eval . |
            jq -c \
                --arg cp "${clsPrfDev}" \
                --argjson creds "$(yq -o json -I 0 eval '
                    .ref.credentials // []
                ' "${hstSrcDir}/${stepCfg}")" \
                --argjson frmImg "$(yq -o json -I 0 eval '
                        .tests[0].steps.test[0] |
                        pick(["from", "from_image"])
                ' "${imgRetrCIcfg}")" \
                --argjson stubStep "$(
                    yq -o json -I 0 eval . 0<<'yamlEOF'
as: ci-op-emul--step
commands: |-
  shopt -op; shopt -p; printenv
  set -eux -o pipefail; shopt -s inherit_errexit
  typeset f=/tmp/test.wait
  typeset -i e=240
  echo "${e}" 1> "${f}"
  while true; do
      read -r e 0< "${f}" || e=0
      ((--e >= 0)) || { rm -f "${f}"; break; }
      echo "${e}" 1> "${f}"
      sleep 60
  done
  true
credentials: []
env: []
resources:
  limits:
    memory: 1Gi
  requests:
    cpu: 100m
    memory: 200Mi
timeout: 24h0m0s
yamlEOF
                )" \
                --argjson noopStep "$(
                    yq -o json -I 0 eval . 0<<'yamlEOF'
as: ci-op-emul--noop
commands: 'true'
from: src
resources:
  requests:
    cpu: 100m
    memory: 200Mi
yamlEOF
                )" \
                '
                    .tests[0]|=(
                        ($stubStep + $frmImg + {
                            "as": ($stubStep.as + "--0"),
                            "credentials": $creds,
                            "env": (
                                (.steps.env // {}) | keys | map({"name": .})
                            )
                        }) as $stub |
                        .steps|=((
                            if (.cluster_profile and ($cp != "")) then
                                .cluster_profile=$cp
                            end
                        ) | (
                            if ((.post | length?) > 0) then (
                                .post+=[$stub]
                            ) elif ((.test | length?) > 0) then (
                                .test+=[$stub] |
                                .post=[($noopStep + {
                                    "as": ($noopStep.as + "--0")
                                })]
                            ) else (
                                .pre+=[$stub] |
                                .test=[($noopStep + {
                                    "as": ($noopStep.as + "--0")
                                })] |
                                .post=[($noopStep + {
                                    "as": ($noopStep.as + "--1")
                                })]
                            )
                            end
                        ))
                    )
                ' |
            yq -p json -o yaml eval .
        } 0<&3 1> "${preTestCIcfg}"

        # Construct Function: ci--to-do
        eval "$(
            cat - 0<<funcEOF; cat - 0<<'funcEOF'
function ci--to-do () {
        cat - 0<<'txtEOF'

================================================================================
The CI Operator Job \`${preTestJobName}\` is ready at:
    ${preTestCIcfg@Q}
The CI Operator Job \`${imgRetrJobName}\` is ready at:
    ${imgRetrCIcfg@Q}
Execute:
    make -C ${hstSrcDir@Q}/ -j 1 ci-operator-config update; echo \$?
Commit the new and modified files, then push that into a (dummy) WIP/Draft PR.
Rehearse the Jobs:
    /pj-rehearse ${preTestJobName}
    /pj-rehearse ${imgRetrJobName}
funcEOF
IMPORTANT!!!
  - This new file is NOT meant to be merged!!! So please do NOT forget to
    remove that CI Configuration file before final merge!!!
  - Some actions below can ONLY be done while the trailing Stub Step Pod is
    still running. Once the Job is terminated, it is no longer possible to
    execute the action and the corresponding Job must be rehearsed again.
Actions:
 1. Run Pre-Test Job to execute all Steps prior to the target Step.
    Once the Pre-Test Job is running, if a CUT (Cluster Under Test) has been
    provisioned and/or reaches the trailing Stub Step:
     a. Synchronize CI Test Environment to local.
            ci--sync--tst-env <dummyPRnum>
        IMPORTANT!!
          - NEED the trailing Stub Step to be running.
        NOTE:
          - (Optional) Only needed when test assets cannot be provided
            manually:
              - CUT credentials needed by `ci--start--ctr` to connect to CUT.
              - Exact `oc` binary used by the target Step.
              - Credentials or shared files required by the Step Script.
     b. Check, reset, or stop the trailing Stub Step execution.
            ci--wait--test [<timeOutInMin>]
        IMPORTANT!!
          - NEED the trailing Stub Step to be running.
        NOTE:
          - The Stub Step will hold the test for 4H by default. Use this
            command to reset the wait time (omit argument or set to a negative
            value to check remaining time, setting it to `0` terminates the
            test).
     c. Pull the target Step Container Image.
            ci--pull--ctr-img 0
        NOTE:
          - (Optional) The Stub Step trailing this Job uses the target Step
            Container. Hence, rehearsing the Image Retrieval Job can be
            avoided. However, this Stub Step is NOT configurable like the Step
            in the Image Retrieval Job.
          - Time limit: 30 min. after Job completion. Once NameSpace is
            deleted, the image cannot be pulled and the Job must be rehearsed
            again.
 2. Run Image Retrieval Job, if the Pre-Test Job was not run or the target Step
    Container Image was not retrieved before the Pre-Test Job completed.
    Once the Image Retrieval Job reaches its Test Step execution:
     a. Pull the target Step Container Image.
            ci--pull--ctr-img
        NOTE:
          - Time limit: 30 min. after Job completion. Once NameSpace is
            deleted, the image cannot be pulled and the Job must be rehearsed
            again.
 3. Run target Step locally.
    Once the target Step Container Image is downloaded successfully, the Test
    Container can be started and the Step Script will be available under
    `/ws/step/` directory inside the Container:
        ci--start--ctr
funcEOF
            cat - 0<<funcEOF; cat - 0<<'funcEOF'
    NOTE:
        User may add additional settings, to be sourced at the start of Test
        Container Interactive Session, in:
            ${ctrCIenvUsr@Q}
funcEOF
To print this message again, execute:
    ci--to-do
================================================================================
txtEOF
}; export -f ci--to-do
funcEOF
        )"
        ci--to-do

        # Construct Function: ci--sync--tst-env
        eval "$(cat - 0<<funcEOF; cat - 0<<'funcEOF'
function ci--sync--tst-env () {(
    set -euo pipefail; shopt -s inherit_errexit
$(
    typeset -p \
        hstCtrFSrootDir hstWSdir \
        ctrWSbinDir \
        ctrCIbldCls_Kcfg \
        preTestCIcfg preTestJobName \
        secretPaths \
        ctrEnvVars
)
funcEOF
    typeset -i prNum="${1:?}"; (($#)) && shift
    typeset jobNS=
    typeset -A envPfxDir=(
        [KUBECONFIG]=cut
        [KUBECONFIGMINIMAL]=cut
        [KUBEADMIN_PASSWORD_FILE]=cut
        [CLUSTER_PROFILE_DIR]=cp
        [SHARED_DIR]=shr
    )
    typeset -A rmtFlsMap=(
        [${ctrWSbinDir}/oc]='which oc'
    )
    typeset stepName="$(yq eval '
        .tests[0].steps | [
            (.pre + .test + .post)[] |
            select(.as | test("^ci-op-emul--noop--\\d+$") | not)
        ][-1].as
    ' "${preTestCIcfg}")"
    typeset podName="$(yq eval '.tests[0].as' "${preTestCIcfg}")-${stepName}"
    export KUBECONFIG="${hstCtrFSrootDir}${ctrCIbldCls_Kcfg}"
    unset KUBEADMIN_PASSWORD_FILE

    # Login to Build Cluster.
    ciEmulOp--Lgn2BuildCls Pre-Test "${preTestJobName}" 'Test Env. sync.'
    jobNS="$(ciEmulOp--GetJobNS ${prNum} "${preTestJobName}")"
    oc project "${jobNS}" -q 1> /dev/null

    # Wait until Stub Step is executing.
    ciEmulOp--Wait4Step ${prNum} "${jobNS}" "${preTestJobName}" "${stepName}"

    # Synchronize CI Test Environment from the executing Pod.
    (
        typeset e= sDir= src= dst=
        typeset hstWStmpDir="${hstWSdir}/tmp"
        typeset kCfgBldCl="${KUBECONFIG}"
        typeset -i i=0
        eval "$(
            # Manual iteration to control order.
            for e in \
                {SHARED,CLUSTER_PROFILE}_DIR \
                KUBE{CONFIG{,MINIMAL},ADMIN_PASSWORD_FILE} \
            ; do
                echo "export ${e}=${ctrEnvVars[$e]}"
            done
        )"

        function RmtGet () {
            typeset rmtCmd="${1:?}"; (($#)) && shift
            oc --kubeconfig "${kCfgBldCl}" -n "${jobNS}" exec \
                "${podName}" \
                -c test \
                -- \
                bash -euc "${rmtCmd}" '' "$@"
        }

        rm -rf "${hstWStmpDir}"
        for e in "${!envPfxDir[@]}"; do
            typeset -n fRef="${e}"
            sDir="${hstWStmpDir}/env/${envPfxDir[${e}]}"; mkdir -p "${sDir}"
            {
                IFS= read -d '' -r src
                tar xzf - -C "${sDir}/"
            } 0< <(
                RmtGet "$(cat - 0<<'rmtEOF'
                    exec 2> /dev/null
                    eval "${1:-}"; (($#)) && shift
                    typeset -a fLst=()
                    typeset -n fRef="${e}"
                    printf '%s\0' "${fRef}"
                    [ -e "${fRef}" ] && fLst+=("${fRef}")
                    tar zcf - -T /dev/null "${fLst[@]}"
rmtEOF
                )" "$(typeset -p e)"
            )
            [ -n "${src}" ] || continue
            [ -n "${fRef}" ] || fRef="${src}"
            src="${sDir}${src}"
            [ -e "${src}" ] || continue
            dst="${hstCtrFSrootDir}${fRef}"; mkdir -p "${dst%/*}"
            [ -d "${src}" ] && rm -rf "${dst}/"
            mv -f "${src}" "${dst}"
        done
        i=0
        for e in "${!rmtFlsMap[@]}"; do
            sDir="${hstWStmpDir}/fls/$((i++))"; mkdir -p "${sDir}"
            {
                IFS= read -d '' -r src
                tar xzf - -C "${sDir}/"
            } 0< <(
                RmtGet "$(cat - 0<<'rmtEOF'
                    exec 2> /dev/null
                    eval "${1:-}"; (($#)) && shift
                    typeset -a fLst=()
                    f="$(eval "${f}" || true)"
                    printf '%s\0' "${f}"
                    [ -e "${f}" ] && fLst+=("${f}")
                    tar zcf - -T /dev/null "${fLst[@]}"
rmtEOF
                )" "$(f="${rmtFlsMap[${e}]}"; typeset -p f)"
            )
            [ -n "${src}" ] || continue
            src="${sDir}${src}"
            [ -e "${src}" ] || continue
            dst="${hstCtrFSrootDir}${e}"; mkdir -p "${dst%/*}"
            [ -d "${src}" ] && rm -rf "${dst}/"
            mv -f "${src}" "${dst}"
        done
        for e in "${!secretPaths[@]}"; do
            sDir="${hstWStmpDir}/crd/${e}"; mkdir -p "${sDir}"
            src="${secretPaths[${e}]}"
            tar xzf - -C "${sDir}/" 0< <(
                RmtGet "$(cat - 0<<'rmtEOF'
                    exec 2> /dev/null
                    eval "${1:-}"; (($#)) && shift
                    typeset -a fLst=()
                    [ -d "${src}" ] && fLst+=("${src}/")
                    tar zcf - -T /dev/null "${fLst[@]}"
rmtEOF
                )" "$(typeset -p src)"
            )
            src="${sDir}${src}"
            [ -d "${src}" ] || continue
            dst="${hstCtrFSrootDir}${e}"; mkdir -p "${dst%/*}"
            cp -rfT "${src}/" "${dst}/"
        done
        rm -rf "${hstWStmpDir}/"
    true )

    cat - 0<<'txtEOF'
----------------------------------------
The Test Environment has been synchronized. All required test assets and
credentials are now available locally.
----------------------------------------
txtEOF

    true
)}; export -f ci--sync--tst-env
funcEOF
        )"

        # Construct Function: ci--wait--test
        eval "$(cat - 0<<funcEOF; cat - 0<<'funcEOF'
function ci--wait--test () {(
    set -euo pipefail; shopt -s inherit_errexit
$(
    typeset -p \
        hstCtrFSrootDir \
        ctrCIbldCls_Kcfg \
        preTestCIcfg preTestJobName
)
funcEOF
    typeset -i waitTime="${1:--1}"; (($#)) && shift
    typeset f='/tmp/test.wait'
    typeset podName="$(yq eval '
        .tests[0] | .as + "-" + (.steps | [
            (.pre + .test + .post)[] |
            select(.as | test("^ci-op-emul--noop--\\d+$") | not)
        ][-1].as)
    ' "${preTestCIcfg}")"
    export KUBECONFIG="${hstCtrFSrootDir}${ctrCIbldCls_Kcfg}"
    unset KUBEADMIN_PASSWORD_FILE

    if ((waitTime < 0)); then
        # Print current remaining.
        oc exec "${podName}" -c test -- cat "${f}" 2> /dev/null || echo 'N/A'
    else
        # Write new wait time (0 = stop, >0 = reset to value).
        oc exec "${podName}" -c test -- bash -c "echo ${waitTime} 1> ${f@Q}"
    fi

    true
)}; export -f ci--wait--test
funcEOF
        )"

        # Construct Function: ci--pull--ctr-img
        eval "$(cat - 0<<funcEOF; cat - 0<<'funcEOF'
function ci--pull--ctr-img () {(
    set -euo pipefail; shopt -s inherit_errexit
$(
    typeset -p \
        hstCtrFSrootDir \
        ctrCIbldCls_Kcfg ctrCIbldCls_ImgSpecInfo \
        preTestJobName imgRetrJobName
)
    typeset ctrImgSpec=":\$(
        yq eval '.ref.from // (
            .ref.from_image |
            .namespace + "-" + .name + "-" + .tag
        )' ${hstSrcDir@Q}/${stepCfg@Q}
    )"
funcEOF
    typeset -i tstNum="${1:-1}"; (($#)) && shift
    export KUBECONFIG="${hstCtrFSrootDir}${ctrCIbldCls_Kcfg}"
    unset KUBEADMIN_PASSWORD_FILE

    # Login to Build Cluster.
    case ${tstNum} in
      (0)
        ciEmulOp--Lgn2BuildCls \
            Pre-Test "${preTestJobName}" 'Test Env. sync.'
        ;;
      (1)
        ciEmulOp--Lgn2BuildCls \
            'Image Retrieval' "${imgRetrJobName}" 'Container Image pull'
        ;;
    esac

    # Get Container Image Pull Specification.
    ctrImgSpec="$(
        oc get ImageStream/pipeline -o yaml |
        yq eval '.status.publicDockerImageRepository'
    )${ctrImgSpec}"
    # Login to CI Operator Registry Server.
    oc registry login
    # Sanity check if there is existing Container Image specification already.
    [ -e "${hstCtrFSrootDir}${ctrCIbldCls_ImgSpecInfo}" ] && {
        [ \
            "$(0< "${hstCtrFSrootDir}${ctrCIbldCls_ImgSpecInfo}")" = \
            "${ctrImgSpec}" \
        ] || {
            cat - 0<<errEOF && false
----------------------------------------
The Container Image specification from \
\`${hstCtrFSrootDir}${ctrCIbldCls_ImgSpecInfo}\`:
    $(0< "${hstCtrFSrootDir}${ctrCIbldCls_ImgSpecInfo}")
The expected Container Image specification is:
    ${ctrImgSpec}
Verify the working directory is correct. If so, rename or delete the file, then
re-run \`ci--pull--ctr-img\` to re-create it.
----------------------------------------
errEOF
        }
    } 1>&2
    # Pull the Container Image.
    {
        podman image pull "${ctrImgSpec}" || {
            podman image exists "${ctrImgSpec}" && {
                cat - 0<<txtEOF
----------------------------------------
WARNING!!!
    The attempt to download a fresh copy of the target Step Container Image
    failed, but it exists already locally. HOWEVER it MAY be old and NOT
    up-to-date.
$(podman image ls "${ctrImgSpec}")
txtEOF
            } || false
        }
    } && {
        echo "${ctrImgSpec}" \
            1> "${hstCtrFSrootDir}${ctrCIbldCls_ImgSpecInfo}" ||
        false
    }

    cat - 0<<'txtEOF'
----------------------------------------
The Test Container can be started and the Step Script will be available under
`/ws/step/` directory inside the Container:
    ci--start--ctr
----------------------------------------
txtEOF

    true
)}; export -f ci--pull--ctr-img
funcEOF
        )"

        # Construct Function: ci--start--ctr
        eval "$(cat - 0<<funcEOF; cat - 0<<'funcEOF'
function ci--start--ctr () {(
    set -euo pipefail; shopt -s inherit_errexit
$(
    typeset -p \
        stepCfg testName ciCfg asUsr \
        hstSrcDir hstCtrFSrootDir hstArtRootDir \
        ctrShell ctrWSdir ctrWSbinDir ctrWSetcDir ctrWStmpDir \
        ctrCIbldCls_Kcfg ctrCIbldCls_ImgSpecInfo \
        ctrCIenvUsr \
        testJobName stepName \
        secretPaths \
        ctrCPdir ctrEnvVars
)
funcEOF
    typeset e= srcFile= tgtFile=
    typeset ciDirPfx=ci
    typeset envCtrFile="${ctrWSdir}/env--ctr"
    typeset ctrCIrootDir="${ctrWSdir}/$(
        date -u "+${ciDirPfx}--%Y%m%dT%H%M%SZ"
    )"; mkdir -p "${hstCtrFSrootDir}${ctrCIrootDir}"
    typeset hstStepDir="${hstSrcDir}/${stepCfg%/*}"
    typeset ctrStepDir="${ctrWSdir}/step"; mkdir -p \
        "${hstCtrFSrootDir}${ctrStepDir}"
    typeset ctrStepScr="${ctrStepDir}/$(
        yq eval '.ref.commands' "${hstSrcDir}/${stepCfg}"
    )"
    typeset podName="${testName}-${stepName}"
    typeset -A envVars=(
        [JOB_NAME]="${testJobName@Q}"
        [JOB_NAME_SAFE]="${testName@Q}"
        [ARTIFACT_DIR]="${ctrCIrootDir@Q}/artifacts"
    ); eval "envVars+=$(typeset -p ctrEnvVars | sed -E 's/^[^=]+=//')"

    # Move prev. run Artifacts (or delete it if none) to Artifact Archive.
    find "${hstCtrFSrootDir}${ctrCIrootDir}/../" "${hstArtRootDir}/" \
        -mindepth 1 -maxdepth 1 \
        -type d -name "${ciDirPfx}--*" ! -name "${ctrCIrootDir##*/}" \
        -exec "${SHELL}" -c '
            case ${1} in
              (${2}*)
                [ -z "$(find "${1}/" -type f)" ] && rm -rf "${1}/"
                ;;
              (*)
                [ -L "${1}/artifacts" ] ||
                    [ -z "$(find "${1}/artifacts/" -type f)" ] ||
                    mv "${1}/artifacts" "${2}/${1##*/}"
                rm -rf "${1}/"
                ;;
            esac
        ' '' '{}' "${hstArtRootDir}" \;
    # Create a fix path to point to current run Artifact directory.
    ln -sf \
        "${ctrCIrootDir##*/}" "${hstCtrFSrootDir}${ctrCIrootDir}/../${ciDirPfx}"

    # Generate Container Env. file.
    cat - 0<<fileEOF 1>"${hstCtrFSrootDir}${envCtrFile}"
# Local Addition.
export PATH=${ctrWSbinDir@Q}":\${PATH}"
export WS__ROOT=${ctrWSdir@Q}
export WS__TMP=${ctrWStmpDir@Q}
export CI__ROOT_DIR=${ctrCIrootDir@Q}
export CI__BLD_CLS__KCFG=${ctrCIbldCls_Kcfg@Q}
# Default CI Operator.
export OPENSHIFT_CI=true
export CI=true
export PROW_JOB_ID=01234567-89ab-cdef-fedc-ba9876543210
$(
    # Manual iteration to control order.
    for e in \
        JOB_NAME{,_SAFE} \
        {SHARED,ARTIFACT,CLUSTER_PROFILE}_DIR \
        KUBE{CONFIG{,MINIMAL},ADMIN_PASSWORD_FILE} \
    ; do
        echo "export ${e}=${envVars[$e]}"
    done
)
# Default from \`Step\`.
$(
    yq -o json e '.ref.env' "${hstSrcDir}/${stepCfg}" |
    jq -r '.[] | "export \(.name)=\((.default // "") | @sh)"'
)
# Overridden by \`Job\`.
$(
    yq -o json e '.tests' "${hstSrcDir}/${ciCfg}" |
    jq -r \
        --arg as "${testName}" \
        '
            .[] | select(.["as"] == $as) | .steps.env| to_entries[] |
            "export \(.key)=\((.value // "") | @sh)"
        '
)
# Additional settings from \`${ctrCIenvUsr}\`.
##  WARNING!!!
##  This file is sourced several times by the Host. Since the content below is
##  user-defined, it may execute something.
##  Only continue if this file is sourced from the Container.
[ "\${__CTR:-0}" = 1 ] || return 0
$([ ! -f "${ctrCIenvUsr}" ] || cat "${ctrCIenvUsr}")
fileEOF

    # Prepare directory structure of Container Root FS.
    for e in "${!envVars[@]}"; do
        [ "${e: -4}" = _DIR ] &&
        tgtFile="${hstCtrFSrootDir}$(
            typeset -n envVarRef="${e}"
            . "${hstCtrFSrootDir}${envCtrFile}"
            echo "${envVarRef}"
        )" &&
        mkdir -p "${tgtFile}"
    done
    # Copy files to be accessible inside Container.
    for e in KUBE{CONFIG{,MINIMAL},ADMIN_PASSWORD_FILE}; do
        eval '
            srcFile="${'"${e}"':-${K8S__CLUSTER_DIR}/auth/$(
                case ${e} in
                  (KUBECONFIGMINIMAL)   e=kubeconfig;;
                  (*)                   eval "e=${envVars[${e}]}";;
                esac
                echo "${e##*/}"
            )}"
        '
        tgtFile="${hstCtrFSrootDir}$(
            typeset -n envVarRef="${e}"
            . "${hstCtrFSrootDir}${envCtrFile}"
            echo "${envVarRef}"
        )"
        [ ! -e "${tgtFile}" ] && [ -e "${srcFile}" ] &&
            mkdir -p "${tgtFile%/*}" && cp "${srcFile}" "${tgtFile}"
    done
    for e in \
        oc \
        tkn tkn-pac opc \
        virtctl \
    ; do
        e="$(which "${e}" 2> /dev/null || true)"
        [ -n "${e}" ] &&
        ln -Lf "${e}" "${hstCtrFSrootDir}${ctrWSbinDir}/" 2> /dev/null || {
            [ ! -e "${hstCtrFSrootDir}${ctrWSbinDir}/${e##*/}" ] &&
            cp -f "${e}" "${hstCtrFSrootDir}${ctrWSbinDir}/"
        }
    done

    # Pre Step.
    (
        # Handle `KUBECONFIG`.
        typeset tgtDir="${hstCtrFSrootDir}$(
            typeset -n envVarRef=WS__TMP
            . "${hstCtrFSrootDir}${envCtrFile}"
            echo "${envVarRef}"
        )"
        find "${hstCtrFSrootDir}${ctrWStmpDir}/" -mindepth 1 -delete
        for e in KUBECONFIG; do
            e="$(
                typeset -n envVarRef="${e}"
                . "${hstCtrFSrootDir}${envCtrFile}"
                echo "${envVarRef}"
            )"
            srcFile="${hstCtrFSrootDir}${e}"
            tgtFile="${tgtDir}/${e#${ctrWSdir}/}"
            if [ -f "${srcFile}" ]; then
                mkdir -p "${tgtFile%/*}"
                cp -f "${srcFile}" "${tgtFile}"
            fi
        done
    )

    # Start the Container.
    cat - 0<<txtEOF
--------------------
Please populate the Secrets, accordingly, in the following Host directories:
$(
    for e in \
        "$(
            . "${hstCtrFSrootDir}${envCtrFile}"
            echo "${CLUSTER_PROFILE_DIR}"
        )" \
        "${secretPaths[@]}" \
    ; do
        e="${hstCtrFSrootDir}${e}/"
        echo "    ${e@Q}"
    done
)
Run the test:
    bash ${ctrStepScr@Q} |& tee "\${ARTIFACT_DIR}/build.log"; echo \${PIPESTATUS[0]}
--------------------
txtEOF
    eval "
        podman container run \\
            --name ci-operator --rm -it \\
            --hostname $(printf '%.63Q' "${podName}") \\
            --cap-add CAP_CHOWN \\
            --env SHELL=${ctrShell@Q} \\
            -v ${hstCtrFSrootDir@Q}${ctrWSdir@Q}/:${ctrWSdir@Q}/:Z \\
            -v ${hstCtrFSrootDir@Q}${ctrCPdir@Q}/:${ctrCPdir@Q}/:ro,Z \\
            -v ${hstStepDir@Q}/:${ctrStepDir@Q}/:ro,Z \\
$(
    for e in "${secretPaths[@]}"; do
        echo "            -v ${hstCtrFSrootDir@Q}${e@Q}/:${e@Q}/:ro,Z \\"
    done
    echo '            \'
)
            ${asUsr:+-u ${asUsr@Q}:0 --group-add ${asUsr@Q}} \\
            --entrypoint '/bin/sh' \\
            -- \"\$(0< "\${hstCtrFSrootDir}\${ctrCIbldCls_ImgSpecInfo}")\" \\
            -c '
                __CTR=1 command . ${envCtrFile@Q}
                [ \$(id -u) -ne 0 ] && {
                    . ${ctrWSetcDir@Q}/bash.bash.login || true
                }
                \"\${SHELL}\" -l
                [ \$(id -u) -ne 0 ] && {
                    . ${ctrWSetcDir@Q}/bash.bash.logout || true
                }
            '
#           ${asUsr:+\
#               -u ${asUsr@Q}:0 --group-add ${asUsr@Q}\
#               --userns keep-id:uid=${asUsr@Q}\
#           } \\
    "
    ((! $?))

    # Post Step.
    (
        # Move current run Artifact directory to Artifact Archive.
        mv -f \
            "${hstCtrFSrootDir}${ctrCIrootDir}/artifacts" \
            "${hstArtRootDir}/${ctrCIrootDir##*/}"
        ln -sf \
            "../../../${hstArtRootDir##*/}/${ctrCIrootDir##*/}" \
            "${hstCtrFSrootDir}${ctrCIrootDir}/artifacts"

        # Handle `KUBECONFIG`, `KUBECONFIGMINIMAL`, and
        #   `KUBEADMIN_PASSWORD_FILE`.
        typeset srcDir="${hstCtrFSrootDir}$(
            typeset -n envVarRef=SHARED_DIR
            . "${hstCtrFSrootDir}${envCtrFile}"
            echo "${envVarRef}"
        )"
        for e in KUBE{CONFIG{,MINIMAL},ADMIN_PASSWORD_FILE}; do
            e="$(
                typeset -n envVarRef="${e}"
                . "${hstCtrFSrootDir}${envCtrFile}"
                echo "${envVarRef}"
            )"
            tgtFile="${hstCtrFSrootDir}${e}"
            srcFile="${srcDir}/${tgtFile##*/}"
            if {
                [ -f "${srcFile}" ] &&
                ! [ "${srcFile}" -ef "${tgtFile}" ]
            }; then
                cp -f "${srcFile}" "${tgtFile}"
                ln -sf "${e}" "${srcFile}"
            fi
        done
    )

)}; export -f ci--start--ctr
funcEOF
        )"

        cat - 0<<txtEOF

Do NOT forget to exit this interactive session!!!
txtEOF
        PROMPT_COMMAND='PS1="${PS1%\[CI Operator Emulator\] }'\
'[CI Operator Emulator] "' "${SHELL}"

        true
cmdEOF
    )"; echo $?
```
</details>
</details>