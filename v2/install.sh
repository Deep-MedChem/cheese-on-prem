#!/bin/bash
# Offline installer for a CHEESE V2 bundle -- everything it needs is in this
# directory. Check the bundle digest with system tools BEFORE running this
# (see docs/v2-offline.md, "Trust bootstrap"); it then re-verifies every file.
#
#   ./install.sh --trusted-digest sha256:<hex> [--prefix DIR] [--link-data]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$here/cli/scripts/cheese-v2" install --bundle "$here" "$@"
