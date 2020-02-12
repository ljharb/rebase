#!/bin/bash

set -e

PR_NUMBER=$(jq -r ".number" "$GITHUB_EVENT_PATH")
echo "Collecting information about PR #$PR_NUMBER of $GITHUB_REPOSITORY..."

if [ -z "$GITHUB_TOKEN" ]; then
	echo "Set the GITHUB_TOKEN env variable."
	exit 1
fi

pr_json=$(gh pr view "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --json baseRefName,headRefName,isCrossRepository,maintainerCanModify,mergeable)

BASE_BRANCH=$(echo "$pr_json" | jq -r .baseRefName)
HEAD_BRANCH=$(echo "$pr_json" | jq -r .headRefName)
IS_CROSS_REPO=$(echo "$pr_json" | jq -r .isCrossRepository)
CAN_MODIFY=$(echo "$pr_json" | jq -r .maintainerCanModify)
MERGEABLE=$(echo "$pr_json" | jq -r .mergeable)

if [ "$MERGEABLE" = "CONFLICTING" ]; then
	>&2 echo 'PR has merge conflicts and cannot be rebased!'
	exit 1
fi

if [ "$MERGEABLE" = "UNKNOWN" ]; then
	>&2 echo 'GitHub has not yet determined if the PR is mergeable. Try again shortly.'
	exit 1
fi

if [ -z "$BASE_BRANCH" ]; then
	>&2 echo "Cannot get base branch information for PR #${PR_NUMBER}!"
	exit 1
fi

if [ "$CAN_MODIFY" != "true" ] && [ "$IS_CROSS_REPO" = "true" ]; then
	>&2 echo 'PR is from a fork, and does not allow edits'
	exit 1
fi

echo "Base branch for PR #${PR_NUMBER} is ${BASE_BRANCH}"

git config --global user.email 'action@github.com'
git config --global user.name 'GitHub Action'

set -o xtrace

# Check out the PR branch using gh
gh pr checkout "$PR_NUMBER"

# Get the local branch name (may differ from HEAD_BRANCH if names collide with base)
LOCAL_BRANCH=$(git symbolic-ref HEAD --short)

# Make sure base branch is up-to-date
git fetch origin "$BASE_BRANCH"

# Count merge commits
MERGE_COUNT=$(git log --oneline "origin/$BASE_BRANCH..HEAD" --merges | wc -l | tr -d '[:space:]')
if [ $? -ne 0 ]; then
	>&2 echo 'Unable to count merge commits'
	exit 1;
fi
if [ $MERGE_COUNT -eq 0 ]; then
	echo 'No merge commits found, yay!'
	exit 0
fi

# Do the rebase
if [ "$GITHUB_REPOSITORY" = 'tc39/ecma262' ]; then
	git rebase -f "origin/$BASE_BRANCH"
else
	git rebase "origin/$BASE_BRANCH" --committer-date-is-author-date
fi

# Push back
if [ "$HEAD_BRANCH" = "$BASE_BRANCH" ]; then
	# When the PR branch name matches the default branch, use pushRemote-style push
	PUSH_REMOTE=$(git config --get "branch.${LOCAL_BRANCH}.pushRemote" 2>/dev/null || git config --get "branch.${LOCAL_BRANCH}.remote")
	MERGE_REF=$(git config --get "branch.${LOCAL_BRANCH}.merge" | awk -F / '{print $NF}')
	git push "${PUSH_REMOTE}" "+HEAD:${MERGE_REF}"
else
	git push --force-with-lease
fi

>&2 echo "${MERGE_COUNT} merge commit(s) found; PR branch rebased."
exit 1
