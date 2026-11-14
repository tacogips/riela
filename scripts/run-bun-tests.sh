#!/usr/bin/env bash
set -euo pipefail

watch_mode="false"
declare -a passthrough_args=()

for arg in "$@"; do
  if [[ "$arg" == "--watch" ]]; then
    watch_mode="true"
    continue
  fi

  passthrough_args+=("$arg")
done

declare -a search_roots=()
for root in scripts packages; do
  if [[ -d "$root" ]]; then
    search_roots+=("$root")
  fi
done

if [[ "${#search_roots[@]}" -eq 0 ]]; then
  echo "No Bun test roots remain after TypeScript source deletion; skipping."
  exit 0
fi

declare -a test_files=()
while IFS= read -r test_file; do
  test_files+=("$test_file")
done < <(rg --files "${search_roots[@]}" -g '*.test.ts' -g '*.test.tsx' | sort)

if [[ "${#test_files[@]}" -eq 0 ]]; then
  echo "No Bun TypeScript tests remain after TypeScript source deletion; skipping."
  exit 0
fi

declare -a command=("bun" "test")

if [[ "$watch_mode" == "true" ]]; then
  command+=("--watch")
fi

command+=("${passthrough_args[@]}")
command+=("${test_files[@]}")

exec "${command[@]}"
