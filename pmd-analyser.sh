# shellcheck shell=sh
ERROR_COUNT=0

# Check whether to use latest version of PMD
if [ "$PMD_VERSION" == 'latest' ]; then
    LATEST_TAG="$(curl -H "Accept: application/vnd.github.v3+json" https://api.github.com/repos/pmd/pmd/releases/latest | jq --raw-output '.tag_name')"
    PMD_VERSION="${LATEST_TAG#"pmd_releases/"}"
fi

# Download PMD
wget https://github.com/pmd/pmd/releases/download/pmd_releases%2F"${PMD_VERSION}"/pmd-bin-"${PMD_VERSION}".zip
unzip pmd-bin-"${PMD_VERSION}".zip
# Now either run the full analysis or files changed based on the settings defined
if [ "$ANALYSE_ALL_CODE" == 'true' ]; then
    pmd-bin-"${PMD_VERSION}"/bin/run.sh pmd -d "$FILE_PATH" -R "$RULES_PATH" -failOnViolation false -f json > pmd-output.json
else
    if [ "$ACTION_EVENT_NAME" == 'pull_request' ]; then
        # Now to determine whether to get the files changed from a git diff or using the files changed in a GitHub Pull Request
        # Both options will generate a CSV file first with the files changed
        if [ "$FILE_DIFF_TYPE" == 'git' ]; then
            git diff --name-only --diff-filter=d origin/"$CURRENT_CODE"..origin/"${CHANGED_CODE#"refs/heads/"}" | paste -s -d "," >> diff-file.csv
        else
            curl -H "Accept: application/vnd.github.v3+json" -H "Authorization: token ${AUTH_TOKEN}" https://api.github.com/repos/"$REPO_NAME"/pulls/"$PR_NUMBER"/files | jq --raw-output '.[] .filename' | paste -s -d "," >> diff-file.csv
        fi
    else
        # Irrespective of the file type diff selected on a push event, we will always do a git diff (as we can't get that from the GitHub API)
        git diff --name-only --diff-filter=d origin/"$CURRENT_CODE"..origin/"$CHANGED_CODE" | paste -s -d "," >> diff-file.csv
    fi
    # Run the analysis
    pmd-bin-"${PMD_VERSION}"/bin/run.sh pmd -filelist diff-file.csv -R "$RULES_PATH" -failOnViolation false -f json > pmd-output.json
fi
# Loop through each file and then loop through each violation identified
 while read -r file; do
    FILENAME="$(echo "$file" | jq --raw-output '.filename | ltrimstr("${{ github.workspace }}/")')"
    while read -r violation; do
        MESSAGE="$(echo "$violation" | jq --raw-output '" \(.ruleset) - \(.rule): \(.description). This applies from line \(.beginline) to \(.endline) and from column \(.begincolumn) to \(.endcolumn). For more information on this rule visit \(.externalInfoUrl)"')"
        LINE="$(echo "$violation" | jq --raw-output '.beginline')"
        COLUMN="$(echo "$violation" | jq --raw-output '.begincolumn')"
        RULE="$(echo "$violation" | jq --raw-output '.rule')"
        if [ -n "$RULE" ]; then
            if [[ "$ERROR_RULES" == *"$RULE"* ]]; then
                echo ::error file="$FILENAME",line="$LINE",col="$COLUMN"::"$MESSAGE"
                ERROR_COUNT=$((ERROR_COUNT + 1))
            else
                echo ::warning file="$FILENAME",line="$LINE",col="$COLUMN"::"$MESSAGE"
            fi
        fi
    done <<< "$(echo "$file" | jq --compact-output '.violations[]')"
done <<< "$(cat pmd-output.json | jq --compact-output '.files[]')"
# If there are any errors logged we want this to fail (warnings don't count)
if [ "$ERROR_COUNT" -gt 0 ]; then
    exit 3
fi