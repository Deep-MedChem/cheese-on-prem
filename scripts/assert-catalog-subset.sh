#!/usr/bin/env bash
# Assert that config/databases.catalog is a SUBSET of what the hosted service
# serves. We never offer on-prem a database we do not serve online — fewer is
# fine, more is not. A customer who selects an unserved database spends hours
# (up to 1.3 TB) downloading something we cannot support.
#
# Two failure modes, both fatal:
#   1. a catalogued folder has no canonical name in scripts/_engine-config
#      -> nothing for a customer to key it by; it cannot be offered at all
#   2. a catalogued database is not in /api/available_dbs
#      -> we are offering more than we serve
#
# The reverse (served online, absent here) is FINE and not reported: SynthonGPT
# databases are served but deliberately outside the on-prem search catalogue.
set -euo pipefail

API="${CHEESE_API:-https://cheese.deepmedchem.com/api}"
here="$(cd "$(dirname "$0")/.." && pwd)"
catalog="$here/config/databases.catalog"
engine_config="$here/scripts/_engine-config"

served="$(curl -sSf --max-time 30 "$API/available_dbs" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(d if isinstance(d,list) else d["available_dbs"]))' \
  | sort)"
[ -n "$served" ] || { echo "FATAL: $API/available_dbs returned nothing" >&2; exit 2; }

unnamed=() unserved=()
while IFS='|' read -r folder _; do
  case "$folder" in ''|'#'*) continue ;; esac
  canonical="$(sed -n '/DB_CANONICAL_NAME/,/^)/p' "$engine_config" \
    | grep -oE "\[$folder\]=\"[A-Za-z0-9_.-]+\"" | sed 's/.*="//; s/"//' || true)"
  if [ -z "$canonical" ]; then unnamed+=("$folder"); continue; fi
  grep -qx "$canonical" <<<"$served" || unserved+=("$folder -> $canonical")
done < "$catalog"

rc=0
if [ ${#unnamed[@]} -gt 0 ]; then
  rc=1; echo "FAIL: catalogued folders with no canonical name in scripts/_engine-config:" >&2
  printf '  %s\n' "${unnamed[@]}" >&2
  echo "  A customer has nothing to key these by. Add a mapping or drop them." >&2
fi
if [ ${#unserved[@]} -gt 0 ]; then
  rc=1; echo "FAIL: catalogued but NOT served by $API:" >&2
  printf '  %s\n' "${unserved[@]}" >&2
  echo "  We never offer on-prem what we do not serve online. Drop them." >&2
fi
n="$(grep -v '^#' "$catalog" | grep -c '|')"
[ $rc -eq 0 ] && echo "OK: all $n catalogued databases are served by $API"
exit $rc
