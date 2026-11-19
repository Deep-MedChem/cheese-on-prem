"""Pre-cutover signature check, run by `cheese v2 install/update`.

Executed inside the backend image that is about to serve the releases (with
--network none), so it uses exactly the verifier the backend will use at
startup. Checks each manifest.sig against RELEASE_PUBLIC_KEY_B64; the file
hashes are checked by the bundle SHA256SUMS and again by the backend itself.

Usage: python -I verify-releases.py MANIFEST [...]   (key in the environment)
Exit codes: 0 all verified, 1 a signature failed, 3 verifier not in this image.
"""

import os
import sys
from pathlib import Path

try:
    from dmc_synthon_core.manifest import verify_release_signature
except ImportError as error:
    print(f"verifier unavailable in this image: {error}", file=sys.stderr)
    sys.exit(3)

key = os.environ.get("RELEASE_PUBLIC_KEY_B64", "")
failed = False
for manifest in sys.argv[1:]:
    try:
        verify_release_signature(Path(manifest), public_key_b64=key)
        print(f"signature ok: {manifest}")
    except Exception as error:  # report every release, not just the first
        print(f"SIGNATURE FAILED: {manifest}: {error}", file=sys.stderr)
        failed = True
sys.exit(1 if failed else 0)
