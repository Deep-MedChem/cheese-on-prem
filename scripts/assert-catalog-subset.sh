#!/usr/bin/env bash
# Assert that config/databases.catalog is a SUBSET of what the hosted service
# serves. We never offer on-prem a database we do not serve online — fewer is
# fine, more is not. A customer who selects an unserved database spends hours
# (up to 1.3 TB) downloading something we cannot support.
#
# Three failure modes, all fatal:
#   1. a catalogued folder has no canonical name in scripts/_engine-config
#      -> nothing for a customer to key it by; it cannot be offered at all
#   2. a catalogued database is not in /api/available_dbs
#      -> we are offering more than we serve
#   3. the Helm chart's database.databases disagrees with the catalogue
#      -> the two delivery paths offer different things. A chart entry naming a
#         retired folder sends a partner's dataSync at a prefix that no longer
#         exists; a missing entry means a database we deliver cannot be enabled
#         on Kubernetes at all.
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
declare -A folder_of=()          # canonical -> catalogued folder, for the chart check
while IFS='|' read -r folder _; do
  case "$folder" in ''|'#'*) continue ;; esac
  canonical="$(sed -n '/DB_CANONICAL_NAME/,/^)/p' "$engine_config" \
    | grep -oE "\[$folder\]=\"[A-Za-z0-9_.-]+\"" | sed 's/.*="//; s/"//' || true)"
  if [ -z "$canonical" ]; then unnamed+=("$folder"); continue; fi
  folder_of["$canonical"]="$folder"
  grep -qx "$canonical" <<<"$served" || unserved+=("$folder -> $canonical")
done < "$catalog"

# ── The Helm chart must offer exactly the catalogue ──────────────────────────
# values.yaml carries one entry per delivered database so a partner enables one
# by flipping a flag. Read the canonical key + output_directory out of it; the
# structure is fixed (4-space key, 6-space fields), so awk is enough and this
# adds no dependency to CI.
chart="$here/k8s/charts/cheese/values.yaml"
chart_missing=() chart_stale=()
if [ -f "$chart" ]; then
  chart_entries="$(awk '
    /^[A-Za-z_]/                        { top=$0; sub(/:.*/,"",top); indb=0 }
    top=="database" && /^  databases:/  { indb=1; next }
    indb && /^  [a-z]/                  { indb=0 }
    indb && /^    [A-Za-z0-9._-]+:/     { key=$1; sub(/:$/,"",key); next }
    indb && /^      output_directory:/  { d=$2; gsub(/"/,"",d); if (key!="test") print key"|"d }
  ' "$chart")"

  while IFS='|' read -r key dir; do
    [ -n "$key" ] || continue
    if [ -z "${folder_of[$key]:-}" ]; then
      chart_stale+=("$key -> $dir  (canonical name not in the catalogue)")
    elif [ "${folder_of[$key]}" != "$dir" ]; then
      chart_stale+=("$key -> $dir  (catalogue delivers ${folder_of[$key]})")
    fi
  done <<<"$chart_entries"

  for canonical in "${!folder_of[@]}"; do
    grep -q "^${canonical}|" <<<"$chart_entries" || chart_missing+=("$canonical (${folder_of[$canonical]})")
  done
fi

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
if [ ${#chart_stale[@]} -gt 0 ]; then
  rc=1; echo "FAIL: k8s/charts/cheese/values.yaml offers what the catalogue does not:" >&2
  printf '  %s\n' "${chart_stale[@]}" >&2
  echo "  A partner enabling one of these syncs a prefix that is not there." >&2
fi
if [ ${#chart_missing[@]} -gt 0 ]; then
  rc=1; echo "FAIL: catalogued but absent from k8s/charts/cheese/values.yaml:" >&2
  printf '  %s\n' "${chart_missing[@]}" >&2
  echo "  These cannot be enabled on Kubernetes. Add an entry (enabled: false)." >&2
fi
n="$(grep -v '^#' "$catalog" | grep -c '|')"
[ $rc -eq 0 ] && echo "OK: all $n catalogued databases are served by $API and offered by the chart"
exit $rc
