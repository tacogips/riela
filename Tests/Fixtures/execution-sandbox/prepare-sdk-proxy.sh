#!/bin/sh
# Verification only: prepare a read-only loopback proxy + worker installation.
# socat is installed in a disposable VM, never in the production runtime image.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
image=${1:-riela-builtin-addons:local}
output=${2:-$repo_root/tmp/execution-sandbox/sdk-proxy-install}
mkdir -p "$output"
container run --rm --name "riela-sdk-proxy-export-$$" --cpus 2 --memory 1G \
  --mount "type=bind,source=$output,target=/export" --entrypoint /bin/sh "$image" -c '
    set -eu
    apt-get update >/dev/null
    apt-get install -y --no-install-recommends socat >/dev/null
    cp -R /opt/riela/. /export/
    cp /usr/bin/socat /export/socat
    mkdir -p /export/proxy-libs
    ldd /usr/bin/socat | awk "/=> \// {print \$3}" |
      while IFS= read -r library; do cp -L "$library" /export/proxy-libs/; done
  ' >&2
mv "$output/riela" "$output/riela-worker"
cp "$repo_root/Tests/Fixtures/execution-sandbox/sdk-proxy-entrypoint.sh" "$output/riela"
chmod 755 "$output/riela"
printf '%s\n' "$output"
