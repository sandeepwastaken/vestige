#!/bin/bash
#
# install.sh — clone and build Vestige in one command.
#
#   VESTIGE_REPOSITORY=https://github.com/owner/vestige.git ./Scripts/install.sh
#
# Equivalent to cloning the repo and running build-app.sh --run by hand. No
# prebuilt binary is downloaded, so nothing here touches Gatekeeper's
# quarantine check — see the "Build from source" section of README.md.
#
set -euo pipefail

REPO_URL="${VESTIGE_REPOSITORY:-}"
SRC_DIR="${VESTIGE_SRC_DIR:-$HOME/vestige}"

if [ -z "$REPO_URL" ]; then
    echo "error: set VESTIGE_REPOSITORY to this repository's HTTPS clone URL." >&2
    exit 1
fi

if [ -d "$SRC_DIR/.git" ]; then
    echo "==> Updating existing checkout in $SRC_DIR"
    git -C "$SRC_DIR" pull --ff-only
elif [ -e "$SRC_DIR" ]; then
    echo "error: $SRC_DIR already exists and is not a Vestige checkout." >&2
    echo "       set VESTIGE_SRC_DIR to build somewhere else." >&2
    exit 1
else
    echo "==> Cloning into $SRC_DIR"
    git clone "$REPO_URL" "$SRC_DIR"
fi

exec "$SRC_DIR/Scripts/build-app.sh" --run
