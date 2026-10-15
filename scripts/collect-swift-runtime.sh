#!/bin/sh
# Collect the transitive Swift shared-library dependencies of release binaries.
# Run only in the trusted Linux builder; ldd is not safe for untrusted binaries.
set -eu

destination=${1:?Usage: collect-swift-runtime.sh destination executable...}
shift
mkdir -p "$destination"
for executable in "$@"; do
  dependencies=$(ldd "$executable")
  if printf '%s\n' "$dependencies" | grep -q 'not found'; then
    echo "Unresolved runtime dependency in $executable" >&2
    exit 1
  fi
  printf '%s\n' "$dependencies" |
    awk '/=> \/usr\/lib\/swift\/linux\// { print $3 }' |
    while IFS= read -r library; do
      cp -L "$library" "$destination/"
    done
done
