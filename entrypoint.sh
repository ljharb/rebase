#!/bin/bash

set -e

# skip if not a PR
echo "Checking if a PR command..."
(jq -r ".pull_request._links.html.href" "$GITHUB_EVENT_PATH") || exit 78

# jq . $GITHUB_EVENT_PATH

PR_NUMBER=$(jq -r ".number" "$GITHUB_EVENT_PATH")
REPO_FULLNAME=$(jq -r ".repository.full_name" "$GITHUB_EVENT_PATH")
echo "Collecting information about PR #$PR_NUMBER of $REPO_FULLNAME..."

if [ -z "$GITHUB_TOKEN" ]; then
	echo "Set the GITHUB_TOKEN env variable."
	exit 1
fi

URI=https://api.github.com
API_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token $GITHUB_TOKEN"

pr_resp=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
          "${URI}/repos/$REPO_FULLNAME/pulls/$PR_NUMBER")

BASE_REPO=$(echo "$pr_resp" | jq -r .base.repo.full_name)
BASE_BRANCH=$(echo "$pr_resp" | jq -r .base.ref)

# echo "API response: $pr_resp"

if [ "$(echo "$pr_resp" | jq -r .rebaseable)" != "true" ]; then
	>&2 echo 'GitHub doesn‘t think that the PR is rebaseable! it probably has merge conflicts'
	exit 1
fi

if [[ -z "$BASE_BRANCH" ]]; then
	>&2 echo "Cannot get base branch information for PR #${PR_NUMBER}!"
	exit 1
fi

HEAD_REPO=$(echo "$pr_resp" | jq -r .head.repo.full_name)
HEAD_BRANCH=$(echo "$pr_resp" | jq -r .head.ref)
REBASEABLE=$(echo "$pr_resp" | jq -r .rebaseable)
CAN_MODIFY=$(echo "$pr_resp" | jq -r .maintainer_can_modify)
IS_FORK=$(echo "$pr_resp" | jq -r .base.repo.fork)

if [ $REBASEABLE != true ]; then
	>&2 echo 'Branch is not rebaseable; has merge conflicts'
	exit 1
fi
if [ $CAN_MODIFY != true ] && [ $IS_FORK = true ]; then
	>&2 echo 'PR is a fork, and does not allow edits'
	exit 1
fi

echo "Base branch for PR #${PR_NUMBER} is ${BASE_BRANCH}"

git remote add --no-tags pr_source https://x-access-token:$GITHUB_TOKEN@github.com/${HEAD_REPO}.git

git remote set-url origin https://x-access-token:$GITHUB_TOKEN@github.com/$REPO_FULLNAME.git
git config --global user.email 'action@github.com'
git config --global user.name 'GitHub Action'

set -o xtrace

# make sure branches are up-to-date
git fetch origin $BASE_BRANCH
git fetch pr_source $HEAD_BRANCH

# do the rebase
git checkout -b $HEAD_BRANCH pr_source/$HEAD_BRANCH
MERGE_COUNT=$(git log --oneline origin/$BASE_BRANCH..pr_source/$HEAD_BRANCH --merges | wc -l | tr -d '[:space:]')
if [ $? -ne 0 ]; then
	>&2 echo 'Unable to count merge commits'
	exit 1;
fi
if [ $MERGE_COUNT -eq 0 ]; then
	echo 'No merge commits found, yay!'
	exit 0
fi
if [ "$REPO_FULLNAME" = 'tc39/ecma262' ]; then
	git rebase -f origin/$BASE_BRANCH
else
	git rebase origin/$BASE_BRANCH --committer-date-is-author-date
fi

# push back
git push pr_source HEAD:$HEAD_BRANCH --force

>&2 echo "${MERGE_COUNT} merge commit(s) found; PR branch rebased."
exit 1
