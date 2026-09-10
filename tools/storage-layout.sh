#!/usr/bin/env bash
# Storage-layout guard for upgradeable (UUPS) contracts.
#
# Each vault binds its own BorrowManager proxy, so implementations are upgraded per vault and a
# layout change that is harmless in one deployment can silently corrupt another. This snapshots the
# layout of every contract listed below and fails CI when it changes.
#
#   tools/storage-layout.sh            # check against the committed snapshot (CI default)
#   tools/storage-layout.sh --update   # regenerate after an INTENTIONAL append-only change
#
# UUPS layout rules: append new variables at the end, never reorder, never change a type, never
# remove. Re-run with --update and review the diff in the PR when you do append.
set -euo pipefail

CONTRACTS=(BorrowManager OwnMarket EUSDManager StakedEUSD)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAP_DIR="$DIR/storage-layout"
MODE="${1:-check}"

# `astId` is a compiler-assigned node id that shifts whenever any source file above it changes, so
# it is stripped — only slot / offset / type / label describe the actual layout.
normalize() {
  python3 -c '
import json, re, sys

# Type ids carry a trailing AST node number (t_struct(Params)13043_storage) that shifts whenever
# any source file above them changes. Strip it so only real layout changes show up as a diff.
strip = lambda t: re.sub(r"\)\d+", ")", t)

d = json.load(sys.stdin)
out = {
    "storage": [
        {"label": e["label"], "slot": e["slot"], "offset": e["offset"], "type": strip(e["type"])}
        for e in d.get("storage", [])
    ],
    "types": {},
}
for name, t in (d.get("types") or {}).items():
    t = dict(t)
    for key in ("base", "value", "key"):
        if key in t:
            t[key] = strip(t[key])
    if "members" in t:
        t["members"] = [
            {"label": m["label"], "slot": m["slot"], "offset": m["offset"], "type": strip(m["type"])}
            for m in t["members"]
        ]
    out["types"][strip(name)] = t
print(json.dumps(out, indent=2, sort_keys=True))
'
}

status=0
for c in "${CONTRACTS[@]}"; do
  snap="$SNAP_DIR/$c.json"
  current="$(forge inspect "$c" storageLayout --json | normalize)"

  if [[ "$MODE" == "--update" ]]; then
    printf '%s\n' "$current" > "$snap"
    echo "updated $snap"
    continue
  fi

  if [[ ! -f "$snap" ]]; then
    echo "ERROR: no snapshot for $c — run: tools/storage-layout.sh --update" >&2
    status=1
    continue
  fi

  if ! diff -u "$snap" <(printf '%s\n' "$current") > /tmp/layout-diff-$c.txt; then
    echo "ERROR: storage layout changed for $c" >&2
    cat /tmp/layout-diff-$c.txt >&2
    echo "" >&2
    echo "If this is an intentional APPEND-ONLY change, run: tools/storage-layout.sh --update" >&2
    status=1
  else
    echo "ok: $c layout unchanged"
  fi
done

exit $status
