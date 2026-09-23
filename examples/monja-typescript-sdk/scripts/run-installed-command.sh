#!/bin/sh
set -eu

if [ "$#" -ne 0 ]; then
  printf '%s\n' 'monja-launcher: arguments are not accepted' >&2
  exit 64
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
riela_root=$(CDPATH='' cd -- "$script_dir/../../.." && pwd -P)
tmp_root="$riela_root/tmp"
runtime_request=${MONJA_EXAMPLE_RUNTIME_DIR:-"$tmp_root/monja-typescript-sdk/single-run"}

if [ ! -d "$tmp_root" ]; then
  printf '%s\n' 'monja-launcher: Riela tmp directory is missing' >&2
  exit 66
fi
if [ ! -d "$runtime_request" ]; then
  printf '%s\n' 'monja-launcher: prepared runtime directory is missing' >&2
  exit 66
fi

tmp_root=$(CDPATH='' cd -- "$tmp_root" && pwd -P)
runtime_dir=$(CDPATH='' cd -- "$runtime_request" && pwd -P)
case "$runtime_dir" in
  "$tmp_root"/monja-typescript-sdk/*) ;;
  *)
    printf '%s\n' 'monja-launcher: runtime directory is outside the permitted Riela tmp tree' >&2
    exit 65
    ;;
esac

consumer_dir="$runtime_dir/consumer"
command_file="$consumer_dir/dist/monja-command.js"
if [ ! -d "$consumer_dir" ] || [ ! -f "$command_file" ]; then
  printf '%s\n' 'monja-launcher: compiled command is not prepared' >&2
  exit 66
fi
canonical_consumer=$(CDPATH='' cd -- "$consumer_dir" && pwd -P)
canonical_dist=$(CDPATH='' cd -- "$consumer_dir/dist" && pwd -P)
if [ "$canonical_consumer" != "$consumer_dir" ] || [ "$canonical_dist" != "$consumer_dir/dist" ] || [ -L "$command_file" ]; then
  printf '%s\n' 'monja-launcher: compiled command path escaped the prepared runtime' >&2
  exit 65
fi

cd "$consumer_dir"
exec node "$command_file"
