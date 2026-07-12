#!/usr/bin/env bash
#
# Publish this directory's pages to the GitHub wiki. The wiki is a separate
# git repository (lyman.wiki.git) that GitHub only creates after the first
# page is saved in the web UI — so the very first publish is: create any
# page at https://github.com/joelhelbling/lyman/wiki (its content will be
# overwritten), then run this script. Every publish after that is just this
# script.
#
# The pages live here, in the main repo, so documentation changes ride
# through pull requests like any other change; the wiki repo is a publish
# target, not a source of truth.
set -euo pipefail

WIKI_REMOTE="git@github.com:joelhelbling/lyman.wiki.git"
PAGES_DIR="$(cd "$(dirname "$0")" && pwd)"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

git clone --depth 1 "$WIKI_REMOTE" "$workdir/wiki"
cp "$PAGES_DIR"/*.md "$workdir/wiki/"

cd "$workdir/wiki"
git add -A
if git diff --cached --quiet; then
  echo "wiki already up to date"
  exit 0
fi
git commit -m "Publish wiki pages from $(git -C "$PAGES_DIR" rev-parse --short HEAD 2>/dev/null || echo "the lyman repo")"
git push origin HEAD
echo "published to https://github.com/joelhelbling/lyman/wiki"
