#!/bin/bash
# Pull the latest LiveContainer nightly source (upstream main) into this fork.
# Fork changes live on branch `main`, mostly in fork/ and Fork/ folders, so merges stay small.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git diff --quiet && git diff --cached --quiet || { echo "Commit or stash your changes first."; exit 1; }
git fetch upstream main
git checkout main
git merge --no-edit upstream/main
git submodule update --init --recursive
echo "Merged upstream/main ($(git rev-parse --short upstream/main)) into main."
