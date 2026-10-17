#!/usr/bin/env bash
# Fetches Chainlink's CCIP 2.0.0 pool and token bytecode for script/ccip/SetupCcipWrapper.s.sol.
#
# The bytecode is Chainlink's own build from the npm package @chainlink/contracts-ccip@2.0.0 (BUSL-1.1, with a
# grant for deploying token pools), so it is downloaded and checked rather than committed.
#
#   tools/fetch-ccip-bytecode.sh   # writes ccip-bytecode/v2_0_0/*.bin
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$DIR/ccip-bytecode/v2_0_0"
URL="https://registry.npmjs.org/@chainlink/contracts-ccip/-/contracts-ccip-2.0.0.tgz"
TARBALL_SHA512="P0KvQtZSYC1LevMSS16jOOSsqZG4g0n/MJdcWGmE0Z5U01NVYd1MnTQJOBPsbu1NWR79DBXPXLvyr9tR5y+tiw=="

declare -A FILES=(
  [lock_release_token_pool.bin]=e3965ac71dbc00b0dc6008bfb938243131f465482cb84ff46068d595232ddd19
  [burn_mint_token_pool.bin]=41836a2d7a86e24d01cb6fa3b52a1d0f91b8b02153d88b7db10d69ce459e2ddd
  [cross_chain_token.bin]=9441c38e91282a64208b1bf5bf30ac6af58178121d40fb5efc823347689f5a4a
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$URL" -o "$tmp/pkg.tgz"
got="$(openssl dgst -sha512 -binary "$tmp/pkg.tgz" | base64 -w0)"
if [[ "$got" != "$TARBALL_SHA512" ]]; then
  echo "tarball integrity mismatch: $got" >&2
  exit 1
fi

tar -xzf "$tmp/pkg.tgz" -C "$tmp" package/bytecode/v2_0_0
mkdir -p "$OUT"
for f in "${!FILES[@]}"; do
  src="$tmp/package/bytecode/v2_0_0/$f"
  sum="$(sha256sum "$src" | cut -d' ' -f1)"
  if [[ "$sum" != "${FILES[$f]}" ]]; then
    echo "$f sha256 mismatch: $sum" >&2
    exit 1
  fi
  cp "$src" "$OUT/$f"
  echo "ok: $f"
done
