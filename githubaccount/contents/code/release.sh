#!/bin/sh
# Prints the github.com page of a release, given its api.github.com URL (from a release notification).
# Looked up when the notification is clicked, not on every poll.
# Usage: release.sh <account> <api-url>
set -e

case "$2" in
    https://api.github.com/repos/*/releases/[0-9]*) ;;
    *) echo "Not a release API URL" >&2; exit 2 ;;
esac

if [ -n "$1" ]; then
    GH_TOKEN=$(gh auth token --hostname github.com --user "$1" 2>/dev/null) || {
        echo "gh is not logged in as $1. Run: gh auth login" >&2
        exit 4
    }
    export GH_TOKEN
fi

gh api "$2" --jq .html_url
