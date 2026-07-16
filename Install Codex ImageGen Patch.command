#!/bin/zsh

set -eu

script_dir="${0:A:h}"
exec /bin/bash "$script_dir/install-codex-imagegen-patch.sh" "$@"
