#!/bin/sh
# push-remote.sh — push this repo to origin (github.com/kkazakov/…).
#
# Direct push if this host has GitHub credentials. If not, set
# PUSH_HOST to a user@host that does — the working tree is synced there
# as a git bundle and pushed from that host:
#
#   PUSH_HOST=me@mydesktop ./build/push-remote.sh
#
# Per AGENTS.md: run this after every fix session's versioned commit.

set -e
cd "$(dirname "$0")/.."

if [ -n "${PUSH_HOST:-}" ]; then
    B=/tmp/cpz-$(date +%s).bundle
    git bundle create "$B" --all
    scp "$B" "$PUSH_HOST:/tmp/cpz-repo.bundle"
    ssh "$PUSH_HOST" '
        set -e
        rm -rf /tmp/cpz-push
        git clone /tmp/cpz-repo.bundle /tmp/cpz-push 2>/dev/null || true
        cd /tmp/cpz-push
        git remote set-url origin https://github.com/kkazakov/cardputer-zero-alpine-linux.git
        git push -u origin HEAD
    '
    rm -f "$B"
    echo "pushed via $PUSH_HOST"
    exit 0
fi

git push -u origin HEAD
echo "pushed"