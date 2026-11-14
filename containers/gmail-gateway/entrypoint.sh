#!/bin/sh
set -eu
umask 077
mkdir -p /tmp/riela-gmail
case "${0##*/}" in
  gmail-gateway-reader|gmail-gateway-draft|gmail-gateway-sender)
    exec "/usr/local/libexec/${0##*/}" "$@"
    ;;
  *) exit 64 ;;
esac
