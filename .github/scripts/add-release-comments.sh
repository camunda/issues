#!/bin/bash

# Script to add release comments to closed issues labeled with version:X and a supported component.
# This script is called by the add-release-comments-to-issues.yml workflow.

set -euo pipefail

COMMENT_MARKER_PREFIX="<!-- release-comment-bot:"
COMMENT_MARKER_SUFFIX=" -->"

# component label -> product display name
declare -A COMPONENT_PRODUCT=(
  ["component:webModeler"]="Web Modeler"
  ["component:web-modeler"]="Web Modeler"
  ["component/web-modeler"]="Web Modeler"
  ["component:camunda-hub"]="Hub"
)

CUTOFF_DATE=$(date -d "-${DAYS_BACK} days" --iso-8601)
echo "Looking for issues closed since: $CUTOFF_DATE"

# GitHub search API does not reliably support OR across label: qualifiers,
# so query each component label separately and union the results.
# Search results already include labels — filter to issues with a version:* label
# in jq to avoid a per-issue fetch later.
CANDIDATES=""
for label in "${!COMPONENT_PRODUCT[@]}"; do
  SEARCH_QUERY="repo:$REPOSITORY is:issue is:closed closed:>=$CUTOFF_DATE label:\"$label\""
  RESULT=$(gh api "search/issues?q=$(echo "$SEARCH_QUERY" | jq -sRr @uri)&per_page=100" \
    --paginate \
    --jq '.items[]
          | select((.pull_request | not) and .state == "closed")
          | . as $i
          | (.labels[].name | select(test("^[Vv]ersion:"))) as $v
          | "\($i.number)\t\($v)"' || true)
  if [ -n "$RESULT" ]; then
    while IFS=$'\t' read -r num ver; do
      [ -z "$num" ] && continue
      CANDIDATES="$CANDIDATES"$'\n'"$num"$'\t'"$ver"$'\t'"$label"
    done <<< "$RESULT"
  fi
done
CANDIDATES=$(echo "$CANDIDATES" | awk 'NF' | sort -u)

if [ -z "$CANDIDATES" ]; then
  echo "No matching closed issues found since $CUTOFF_DATE"
  exit 0
fi

echo "Candidate issues: $(echo "$CANDIDATES" | awk -F'\t' '{print $1}' | sort -u | tr '\n' ' ')"

while IFS=$'\t' read -r ISSUE_NUMBER VERSION_LABEL COMPONENT_LABEL; do
  [ -z "$ISSUE_NUMBER" ] && continue
  echo ""
  echo "Processing issue #$ISSUE_NUMBER..."

  VERSION="${VERSION_LABEL#version:}"
  VERSION="${VERSION#Version:}"
  PRODUCT="${COMPONENT_PRODUCT[$COMPONENT_LABEL]}"
  MARKER="${COMMENT_MARKER_PREFIX}${VERSION}${COMMENT_MARKER_SUFFIX}"

  COMMENT_EXISTS=$(gh api "repos/$REPOSITORY/issues/$ISSUE_NUMBER/comments?per_page=100" \
    --paginate \
    --jq ".[] | select(.body | contains(\"$MARKER\")) | .id" | head -n 1 || true)
  if [ -n "$COMMENT_EXISTS" ]; then
    echo "  Skipping #$ISSUE_NUMBER — release comment for $VERSION already exists"
    continue
  fi

  COMMENT_BODY="${MARKER}
This was released in ${PRODUCT} version ${VERSION}"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "  [DRY RUN] Would add comment to #$ISSUE_NUMBER:"
    echo "  $COMMENT_BODY"
  else
    echo "  Adding comment to #$ISSUE_NUMBER (${PRODUCT} ${VERSION})"
    gh api "repos/$REPOSITORY/issues/$ISSUE_NUMBER/comments" \
      -f body="$COMMENT_BODY" > /dev/null
    echo "  ✓ Comment added"
  fi
done <<< "$CANDIDATES"

echo ""
echo "Release comment processing completed."
