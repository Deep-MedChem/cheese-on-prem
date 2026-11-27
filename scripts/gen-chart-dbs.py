#!/usr/bin/env python3
"""Regenerate `database.databases` in the Helm chart from the catalogue.

The chart carries one entry per delivered database so a partner enables one by
flipping a flag. Each entry needs four facts, and no single file holds them all:

  output_directory  config/databases.catalog        (folder in the bucket)
  the canonical key scripts/_engine-config          (folder -> canonical name)
  index_type        the hosted service              (how the index is laid out)
  delimiter         the hosted service              (how the payload splits)

The last two are decided where the databases are built, not here, so they are
read from the hosted service's own metadata endpoint rather than typed in.
That endpoint is public and unauthenticated — the same one
scripts/assert-catalog-subset.sh already uses — which is the point: keeping the
chart in step with what we serve needs no credential in this repository and no
access from it to any private one.

Getting either field wrong is not cosmetic. A wrong index_type makes the engine
reject the folder at startup; a delimiter of "," where the payload is tab-
separated splits every line in the wrong place and returns wrong SMILES and
wrong IDs, silently. So this refuses to emit a partial entry.

Usage:
  gen-chart-dbs.py            print the block to stdout
  gen-chart-dbs.py --check    exit 1 if the chart disagrees with the sources
  gen-chart-dbs.py --write    rewrite the block in the chart in place

Exit codes: 0 agrees, 1 disagrees, 2 could not tell (the service was
unreachable). A caller that alerts should keep those apart — a network blip is
not drift.

`enabled:` is never overwritten — whatever the chart says today is preserved,
and a database new to the catalogue arrives as `enabled: false`. Entries that
are not in the catalogue (the in-repo `test` fixture) are passed through
untouched: this owns the delivered databases, not the whole block.
"""
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
CATALOG = HERE / "config" / "databases.catalog"
ENGINE_CONFIG = HERE / "scripts" / "_engine-config"
CHART = HERE / "k8s" / "charts" / "cheese" / "values.yaml"
API = os.environ.get("CHEESE_API", "https://cheese.deepmedchem.com/api")

# Column the trailing size comment starts at, matching the chart's existing
# alignment. Keys longer than this still get one space.
COMMENT_COL = 43

# Emitted before the first disabled entry. Lives here rather than in the chart
# because --write regenerates the block: edit the wording here, not there.
BANNER = """\
    # ==========================================================================
    # OFF ON PURPOSE — do not flip anything below in THIS file.
    #
    # With dataSync enabled, `enabled: true` starts a download: from a few GiB to
    # 1.2 TiB for a single database. Turning one on here would silently opt in
    # every install that layers a profile on this file. Enable what you want in
    # YOUR values file, where the disk it lands on is yours to check.
    # =========================================================================="""


def human(size_bytes):
    """Match the size comments already in the chart: 625 MiB, 4.8 GiB, 1.2 TiB."""
    value = float(size_bytes)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    i = 0
    while value >= 1024 and i < len(units) - 1:
        value /= 1024
        i += 1
    return f"{value:.0f} {units[i]}" if i <= 2 else f"{value:.1f} {units[i]}"


def read_catalog():
    """[(folder, bytes)] in file order."""
    rows = []
    for line in CATALOG.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        rows.append((fields[0], int(fields[1]) if len(fields) > 1 and fields[1] else 0))
    return rows


def read_canonical_names():
    """folder -> canonical name, from the bash associative array."""
    src = ENGINE_CONFIG.read_text(encoding="utf-8")
    match = re.search(r"declare -A DB_CANONICAL_NAME=\((.*?)\n\)", src, re.S)
    if not match:
        sys.exit("FATAL: DB_CANONICAL_NAME table not found in scripts/_engine-config")
    return dict(re.findall(r"\[([^\]]+)\]=\"([^\"]+)\"", match.group(1)))


def fetch_served_fields():
    """canonical -> {"index_type":..., "delimiter":...} from the hosted service.

    Databases with no index and no delimited payload (the synthon-backed ones)
    carry neither field; they are not delivered on-prem so they never resolve.
    """
    url = f"{API}/databases"
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            payload = json.load(response)
    except Exception as exc:
        print(f"UNKNOWN: cannot read {url}: {exc}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(payload, dict) or not payload:
        print(f"UNKNOWN: {url} returned nothing usable", file=sys.stderr)
        sys.exit(2)

    fields = {}
    for name, row in payload.items():
        if not isinstance(row, dict):
            continue
        entry = {k: row[k] for k in ("index_type", "delimiter") if k in row}
        if entry:
            fields[str(name)] = entry
    # Not one database described means the service does not publish these
    # fields at all (an older deployment), not that every entry drifted at once.
    if not fields:
        print(f"UNKNOWN: {url} publishes no index_type/delimiter for any database",
              file=sys.stderr)
        sys.exit(2)
    return fields


# ── chart block parsing ─────────────────────────────────────────────────────
# The block is a fixed shape (4-space keys, 6-space fields), so this reads it
# without adding a YAML dependency to a script that runs on a bare runner.

def locate_block(lines):
    """(start, end) line indices of `  databases:` under top-level `database:`."""
    section = None
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^[A-Za-z_]", line):
            section = line.split(":", 1)[0]
            continue
        if start is None:
            if section == "database" and line.startswith("  databases:"):
                start = i
            continue
        # First key back at the parent's indent ends the block.
        if re.match(r"^  [A-Za-z_]", line):
            return start, i
    if start is None:
        sys.exit("FATAL: no `databases:` block under `database:` in the chart")
    return start, len(lines)


def parse_entries(block):
    """{key: {"enabled":bool, "lines":[verbatim]}} in file order."""
    entries = {}
    key = None
    for line in block:
        match = re.match(r"^    ([A-Za-z0-9._-]+):", line)
        if match:
            key = match.group(1)
            entries[key] = {"enabled": False, "lines": [line]}
            continue
        if key and re.match(r"^      \S", line):
            entries[key]["lines"].append(line)
            if re.match(r"^      enabled:\s*true\b", line):
                entries[key]["enabled"] = True
    return entries


def render(catalog, canonical, served, existing):
    """The full `  databases:` block, as a list of lines."""
    resolved, unresolved = [], []
    for folder, size in catalog:
        key = canonical.get(folder)
        fields = served.get(key, {}) if key else {}
        if not key or "index_type" not in fields or "delimiter" not in fields:
            unresolved.append((folder, key, fields))
            continue
        resolved.append((key, folder, size, fields))

    if unresolved:
        print("FATAL: refusing to emit a partial block — unresolved databases:", file=sys.stderr)
        for folder, key, fields in unresolved:
            if not key:
                why = "no canonical name in scripts/_engine-config"
            elif not fields:
                why = f"{key} carries no index_type/delimiter at {API}/databases"
            else:
                why = f"{key} is missing {sorted({'index_type', 'delimiter'} - set(fields))}"
            print(f"  {folder}: {why}", file=sys.stderr)
        print("  Add the mapping, drop the database, or check what the service serves.",
              file=sys.stderr)
        sys.exit(1)

    catalogued = {key for key, _, _, _ in resolved}
    out = ["  databases:"]

    # Anything not delivered from the catalogue (the in-repo `test` fixture) is
    # not ours to rewrite — pass it through exactly as found, first.
    for key, entry in existing.items():
        if key not in catalogued:
            out.extend(entry["lines"])

    # Cheapest first, so the sizes a reader scans past are the small ones.
    resolved.sort(key=lambda row: row[2])
    enabled = [r for r in resolved if existing.get(r[0], {}).get("enabled", False)]
    disabled = [r for r in resolved if not existing.get(r[0], {}).get("enabled", False)]

    for row in enabled:
        out.extend(entry_lines(*row, enabled=True))
    if disabled:
        out.append("")
        out.extend(BANNER.splitlines())
        for row in disabled:
            out.extend(entry_lines(*row, enabled=False))
    return out


def entry_lines(key, folder, size, fields, enabled):
    head = f"    {key}:"
    if size:
        head = f"{head}{' ' * max(1, COMMENT_COL - len(head))}# {human(size)}"
    return [
        head,
        f"      enabled: {'true' if enabled else 'false'}",
        f'      output_directory: "{folder}"',
        f"      index_type: {json.dumps(fields['index_type'])}",
        f"      delimiter: {json.dumps(fields['delimiter'])}",
    ]


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("", "--check", "--write"):
        sys.exit(__doc__)

    lines = CHART.read_text(encoding="utf-8").splitlines()
    start, end = locate_block(lines)
    current = lines[start:end]
    # Blank lines at the end are the file's spacing before the next key, not
    # part of the block. Set them aside so --write puts them back.
    trailing = []
    while current and not current[-1].strip():
        trailing.insert(0, current.pop())

    generated = render(read_catalog(), read_canonical_names(),
                       fetch_served_fields(), parse_entries(current))

    if mode == "--check":
        if generated == current:
            n = len(read_catalog())
            print(f"OK: the chart's {n} database entries match the catalogue and {API}")
            return 0
        import difflib
        print(f"FAIL: k8s/charts/cheese/values.yaml disagrees with the catalogue and {API}:",
              file=sys.stderr)
        for line in difflib.unified_diff(current, generated, "chart (now)",
                                         "generated", lineterm="", n=2):
            print(f"  {line}", file=sys.stderr)
        print("\n  Run scripts/gen-chart-dbs.py --write to resync.", file=sys.stderr)
        return 1

    if mode == "--write":
        if generated == current:
            print("Already in sync; chart unchanged.")
            return 0
        CHART.write_text(
            "\n".join(lines[:start] + generated + trailing + lines[end:]) + "\n",
            encoding="utf-8")
        print(f"Rewrote {CHART.relative_to(HERE)} ({len(generated)} lines).")
        return 0

    print("\n".join(generated))
    return 0


if __name__ == "__main__":
    sys.exit(main())
