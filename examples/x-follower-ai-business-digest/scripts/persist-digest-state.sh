#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$script_dir/../../shared/scripts/x_digest.py" persist-state
