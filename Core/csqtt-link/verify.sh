#!/usr/bin/env bash
# Quick verification of a csqtt:// link via the compiled CLI.
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <csqtt://...>" >&2
    exit 2
fi

cd "$(dirname "$0")"
cargo run --quiet -- --url "$1"
