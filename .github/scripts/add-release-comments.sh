#!/bin/bash

# Script to add release comments to closed issues labeled with version:X and a supported component.
# This script is called by the add-release-comments-to-issues.yml workflow.

set -euo pipefail

COMMENT_MARKER="<!-- release-comment-bot -->"

# component label -> product display name
declare -A COMPONENT_PRODUCT=(
  ["component:webModeler"]="Web Modeler"
  ["component:camunda-hub"]="Hub"
)

CUTOFF_DATE=$(date -d "-${DAYS_BACK} days" --iso-8601)
echo "Looking for issues closed since: $CUTOFF_DATE"

# Build search query: closed issues (no PRs) updated within the window, in this repo
# We use search API so we can pre-filter by labels and update window.
SEARCH_QUERY="repo:$REPOSITORY is:issue is:closed closed:>=$CUTOFF_DATE"

# Fetch matching issue numbers
ISSUE_NUMBERS=$(gh api "search/issues?q=$(echo "$SEARCH_QUERY" | jq -sRr @uri)&per_page=100" \
  --paginate \
  --jq '.items[] | select(.pull_request | not) | .number' || true)

if [ -z "$ISSUE_NUMBERS" ]; then
  echo "No closed issues found since $CUTOFF_DATE"
  exit 0
fi

echo "Candidate issues: $(echo "$ISSUE_NUMBERS" | tr '\n' ' ')"

for ISSUE_NUMBER in $ISSUE_NUMBERS; do
  echo ""
  echo "Processing issue #$ISSUE_NUMBER..."

  ISSUE_INFO=$(gh api "repos/$REPOSITORY/issues/$ISSUE_NUMBER" 2>/dev/null || true)
  if [ -z "$ISSUE_INFO" ]; then
    echo "  Issue #$ISSUE_NUMBER not found or not accessible"
    continue
  fi

  IS_PR=$(echo "$ISSUE_INFO" | jq -r '.pull_request // empty')
  if [ -n "$IS_PR" ]; then
    echo "  Skipping #$ISSUE_NUMBER — it's a pull request"
    continue
  fi

  STATE=$(echo "$ISSUE_INFO" | jq -r '.state')
  if [ "$STATE" != "closed" ]; then
    echo "  Skipping #$ISSUE_NUMBER — issue is not closed (state: $STATE)"
    continue
  fi

  LABELS=$(echo "$ISSUE_INFO" | jq -r '.labels[].name')

  VERSION_LABEL=$(echo "$LABELS" | grep -iE '^version:' | head -n 1 || true)
  if [ -z "$VERSION_LABEL" ]; then
    echo "  Skipping #$ISSUE_NUMBER — no version: label"
    continue
  fi
  VERSION="${VERSION_LABEL#version:}"
  VERSION="${VERSION#Version:}"

  COMPONENT_LABEL=""
  PRODUCT=""
  for label in "${!COMPONENT_PRODUCT[@]}"; do
    if echo "$LABELS" | grep -Fxq "$label"; then
      COMPONENT_LABEL="$label"
      PRODUCT="${COMPONENT_PRODUCT[$label]}"
      break
    fi
  done
  if [ -z "$COMPONENT_LABEL" ]; then
    echo "  Skipping #$ISSUE_NUMBER — no supported component label"
    continue
  fi

  COMMENT_EXISTS=$(gh api "repos/$REPOSITORY/issues/$ISSUE_NUMBER/comments?per_page=100" \
    --paginate \
    --jq ".[] | select(.body | contains(\"$COMMENT_MARKER\")) | .id" | head -n 1 || true)
  if [ -n "$COMMENT_EXISTS" ]; then
    echo "  Skipping #$ISSUE_NUMBER — release comment already exists"
    continue
  fi

  COMMENT_BODY="${COMMENT_MARKER}
This was released in version ${PRODUCT} ${VERSION}."

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "  [DRY RUN] Would add comment to #$ISSUE_NUMBER:"
    echo "  $COMMENT_BODY"
  else
    echo "  Adding comment to #$ISSUE_NUMBER (${PRODUCT} ${VERSION})"
    gh api "repos/$REPOSITORY/issues/$ISSUE_NUMBER/comments" \
      -f body="$COMMENT_BODY" > /dev/null
    echo "  ✓ Comment added"
  fi
done

echo ""
echo "Release comment processing completed."
