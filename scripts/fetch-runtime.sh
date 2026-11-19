#!/bin/sh
# Download the Kettlecorn runtime (beam.wasm, OTP and Elixir .beam files) into
# priv/runtime. The archive is per platform because it carries Kettlecorn's
# native launcher; beam.wasm and the root inside are the same on every
# platform, so any of the three works here.
set -eu

VERSION=0.1.0
SYSTEM=aarch64-darwin
SHA256=daa84982b463af92cfb021b2e93c6b2d9be31adf24a6790f21e0086bb0d082de
NAME="kettlecorn-runtime-$VERSION-$SYSTEM"
URL="https://github.com/mjrusso/kettlecorn/releases/download/v$VERSION/$NAME.tar.gz"

here=$(cd "$(dirname "$0")/.." && pwd)
dest="$here/priv/runtime"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/runtime.tar.gz" "$URL"
echo "$SHA256  $tmp/runtime.tar.gz" | shasum -a 256 -c -
tar -xzf "$tmp/runtime.tar.gz" -C "$tmp"
rm -rf "$dest"
mkdir -p "$here/priv"
mv "$tmp/$NAME" "$dest"
# The native launcher is not used: erlang_wasm is the host here.
rm -rf "$dest/bin"
echo "runtime in $dest"
