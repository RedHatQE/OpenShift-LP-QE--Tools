# Back Up
## Back Up Handling
<details><summary>Export / Import Confluence (Cloud) Page</summary>

```shell
( set -euo pipefail; shopt -s inherit_errexit
    pageID=...pageID...
    WIKI_AUTH_CLOUD='...usr...:...token...'
    WIKI_BASE_URL='https://redhat.atlassian.net/wiki'
    WIKI_API_URL="${WIKI_BASE_URL}/api/v2/pages/${pageID}"

    function dlPage () {
        {
            curl -fsSL \
                -u "${WIKI_AUTH_CLOUD}"\
                "${WIKI_API_URL}?body-format=storage" |
            jq -r '.body.storage.value'
        }
        true
    }
    function ulPage () {
        typeset -a pageInfo=()
        IFS=$'\n' read -d '' -ra pageInfo 0< <(
            curl -fsSL -u "${WIKI_AUTH_CLOUD}" "${WIKI_API_URL}" |
            jq -r '.title, .version.number'
        ) || true
        curl -fsSL -X PUT \
            -u "${WIKI_AUTH_CLOUD}" \
            -H 'Accept: application/json' \
            -H 'Content-Type: application/json' \
            -o /dev/null \
            --write-out 'HTTP Response Code: %{http_code}\n' \
            --data-binary @<(
                jq -cnr \
                    --arg id "${pageID}" \
                    --arg title "${pageInfo[0]}" \
                    --arg ver "$((++pageInfo[1]))" \
                    --arg val "$(cat -)" \
                    '
                        {
                            "id": $id,
                            "status": "current",
                            "type": "page",
                            "title": $title,
                            "version": {"number": $ver},
                            "body": {
                                "representation": "storage",
                                "value": $val
                            }
                        }
                    '
            ) "${WIKI_API_URL}"
        true
    }

    dlPage
#   ulPage
true )
```
</details>
<details><summary>Export / Import Confluence (Data Center) Page</summary>

```shell
( set -euo pipefail; shopt -s inherit_errexit
    pageID=...pageID...
    WIKI_TOKEN='...'
    WIKI_BASE_URL='https://spaces.redhat.com'
    WIKI_API_URL="${WIKI_BASE_URL}/rest/api/content/${pageID}"

    function dlPage () {
        {
            curl -fsSL \
                -H "Authorization: Bearer ${WIKI_TOKEN}"\
                "${WIKI_API_URL}?expand=body.storage" |
            jq -r '.body.storage.value'
        }
        true
    }
    function ulPage () {
        typeset -a pageInfo=()
        IFS=$'\n' read -d '' -ra pageInfo 0< <(
            curl -fsSL -H "Authorization: Bearer ${WIKI_TOKEN}" "${WIKI_API_URL}" |
            jq -r '.title, .version.number'
        ) || true
        curl -fsSL -X PUT \
            -H "Authorization: Bearer ${WIKI_TOKEN}" \
            -H 'Accept: application/json' \
            -H 'Content-Type: application/json' \
            -o /dev/null \
            --write-out 'HTTP Response Code: %{http_code}\n' \
            --data-binary @<(
                jq -cnr \
                    --arg id "${pageID}" \
                    --arg title "${pageInfo[0]}" \
                    --arg ver "$((++pageInfo[1]))" \
                    --arg val "$(cat -)" \
                    '
                        {
                            "id": $id,
                            "type": "page",
                            "title": $title,
                            "version": {"number": $ver},
                            "body": {
                                "storage": {
                                    "representation": "storage",
                                    "value": $val
                                }
                            }
                        }
                    '
            ) "${WIKI_API_URL}"
        true
    }

    dlPage
#   ulPage
true )
```
</details>


## Offsite Processing
<details><summary>Getting Macro Content</summary>

```shell
XPATH0='//ac:structured-macro[@ac:macro-id=\"${mID}\"]/ac:plain-text-body' \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        typeset inFile="${1}"; (($#)) && shift
        typeset mID="${1}"; (($#)) && shift
        typeset xPath0="$(eval "echo \"${XPATH0}\"")"

        xmlstarlet select -P \
            -t -m "${xPath0}" -c 'node()' \
            0< <(cat - 0<<htmlEOF
<!DOCTYPE html>
<html lang="en" \
    xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/" \
    xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/" \
>"
<body>
$(0< "${inFile}")
</body>
</html>
htmlEOF
        )

        true
cmdEOF
    )" '' ...inFile... ...mID...
```
</details>
<details><summary>Preparing Macro Content</summary>

```shell
# Prettying HTML (will remove white-space after `anchor` kind elements!!!)
tidy -q -i -w 0 -xml ...inFile...
# Restoring it.
gawk '
    BEGIN{RS="<!\\[CDATA\\[|]]>"}
    {
        if (NR%2) {
            gsub(/\n\s*/,"")
            printf("%s",gensub(/(<\/a(c:link)?>)([^<;:,.!?])/,"\\1 \\3","g"))
        } else {
            printf("<![CDATA[%s]]>",$0)
        }
    }
    END{printf("\n")}
' ...inFile...
```
</details>
<details><summary>Updating Macro Content</summary>

```shell
XPATH0='//ac:structured-macro[@ac:macro-id=\"${mID}\"]/ac:plain-text-body' \
    bash -o pipefail -O inherit_errexit -euc "$(cat - 0<<'cmdEOF'
        typeset inFile="${1}"; (($#)) && shift
        typeset mID="${1}"; (($#)) && shift
        typeset mVal="${1}"; (($#)) && shift
        typeset xPath0="$(eval "echo \"${XPATH0}\"")"

        xmlstarlet edit -P -O \
            -u "${xPath0}" -v __CDATA__ \
            0< <(cat - 0<<htmlEOF
<!DOCTYPE html>
<html lang="en" \
    xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/" \
    xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/" \
>"
<body>
$(0< "${inFile}")
</body>
</html>
htmlEOF
        ) | sed 's|__CDATA__|<![CDATA['"$(
            printf '%q' "$(
                echo "${mVal}" | sed -E 's/\|/\|/g'
            )" | sed -E "s/^\\\$'//;s/&/\\\&/g;s/'$//"
        )"']]>|' | tail -n +4 | head -n -2

        true
cmdEOF
    )" '' ...inFile... ...mID... ...mVal...
```
</details>
