"""Tests for the offline CHEESE V2 path: producer, verification, install,
start/status/stop and update. Docker is replaced by tests/v2/fake_docker.py,
so nothing here starts a container; one test renders the compose file with the
real `docker compose config` when Docker is available.

    python3 -m unittest discover -s tests/v2 -v
"""

import base64
import hashlib
import http.server
import json
import os
import shutil
import socket
import stat
import subprocess
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PRODUCER = REPO / "v2" / "build-offline-bundle"
CHEESE = REPO / "scripts" / "cheese"
BACKEND_ID = "sha256:" + "b" * 64
UI_ID = "sha256:" + "c" * 64
REAL_DOCKER = shutil.which("docker")


def ed25519_public_key_b64(directory: Path) -> str:
    private = directory / "release.key"
    subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", private], check=True)
    der = subprocess.run(
        ["openssl", "pkey", "-in", private, "-pubout", "-outform", "DER"],
        check=True,
        capture_output=True,
    ).stdout
    return base64.b64encode(der).decode()


class _Health(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        ok = self.path in ("/health", "/health/live", "/health/ready")
        self.send_response(200 if ok else 404)
        self.end_headers()
        self.wfile.write(b'{"status":"ready"}' if ok else b"")

    def log_message(self, *args):
        pass


class OfflineBundleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="cheese-v2-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.home.mkdir()
        bin_dir = self.tmp / "fakebin"
        bin_dir.mkdir()
        shim = bin_dir / "docker"
        shim.write_text(f"#!/bin/sh\nexec python3 {REPO / 'tests/v2/fake_docker.py'} \"$@\"\n")
        shim.chmod(0o755)
        self.state = self.tmp / "docker-state.json"
        self.env = {
            "HOME": str(self.home),
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_DOCKER_STATE": str(self.state),
            "LC_ALL": "C",
        }
        self.docker_state(
            images={"dmc/backend:test": BACKEND_ID, "dmc/ui:test": UI_ID},
            projects={},
            preflight_exit=0,
            unhealthy_images=[],
        )
        self.key = ed25519_public_key_b64(self.tmp)
        self.prefix = self.home / ".local/share/cheese-v2"

    # ── helpers ──────────────────────────────────────────────────────────────

    def docker_state(self, **updates):
        state = json.loads(self.state.read_text()) if self.state.exists() else {}
        state.update(updates)
        self.state.write_text(json.dumps(state))
        return state

    def docker_calls(self):
        path = self.tmp / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def run_cmd(self, *args, check=True, env=None):
        result = subprocess.run(
            [str(a) for a in args],
            env={**self.env, **(env or {})},
            capture_output=True,
            text=True,
            timeout=120,
        )
        if check and result.returncode != 0:
            self.fail(f"{args} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
        return result

    def payload(self, name="payload", releases=None, key=None, models=b"model-v1"):
        root = self.tmp / name
        for db, rel in (releases or {"mcule-aa-in-stock": "r2026-11-01"}).items():
            release = root / "releases" / db / rel
            release.mkdir(parents=True)
            data = os.urandom(1024)
            (release / "data.bin").write_bytes(data)
            # Like real manifests, commit to the content of every release file.
            manifest = {"database_id": db, "release_id": rel, "files": {"data.bin": hashlib.sha256(data).hexdigest()}}
            (release / "manifest.json").write_text(json.dumps(manifest))
            (release / "manifest.sig").write_bytes(b"\x01" * 64)
        (root / "models" / "shapesim").mkdir(parents=True)
        (root / "models" / "shapesim" / "weights.bin").write_bytes(models)
        (root / "models" / "manifest.json").write_text(json.dumps({"schema_version": 1, "files": {}, "m": models.decode()}))
        (root / "release-public-key.txt").write_text((key or self.key) + "\n")
        return root

    def build(self, payload, name="bundle", epoch=1_800_000_000, extra=(), check=True):
        output = self.tmp / name
        result = self.run_cmd(
            PRODUCER,
            "--backend-image", "dmc/backend:test",
            "--ui-image", "dmc/ui:test",
            "--payload", payload,
            "--output", output,
            *extra,
            check=check,
            env={"SOURCE_DATE_EPOCH": str(epoch)},
        )
        if not check:
            return result
        digest = result.stdout.strip().splitlines()[-1].split("=", 1)[1]
        return output, digest

    def install(self, bundle, digest, *extra, check=True):
        return self.run_cmd(bundle / "install.sh", "--trusted-digest", digest, *extra, check=check)

    def cheese(self, *args, check=True):
        # The installed CLI, through the classic dispatcher.
        return self.run_cmd(self.prefix / "bin/cheese", "v2", *args, check=check)

    def health_servers(self):
        ports = []
        for _ in range(2):
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Health)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            ports.append(server.server_address[1])
        (self.prefix / "config/v2.conf").write_text(
            f"CHEESE_V2_BIND=127.0.0.1\nCHEESE_V2_UI_PORT={ports[0]}\nCHEESE_V2_API_PORT={ports[1]}\n"
        )
        return ports

    def project(self):
        return dict(
            line.split("=", 1) for line in (self.prefix / "state/installed.env").read_text().splitlines()
        )["PROJECT"]

    # ── producer ─────────────────────────────────────────────────────────────

    def test_producer_writes_complete_checksummed_bundle(self):
        bundle, digest = self.build(self.payload(), extra=("--bundle-version", "pilot-1"))
        self.assertRegex(digest, r"^sha256:[0-9a-f]{64}$")
        self.assertEqual((self.tmp / "bundle.digest").read_text().strip(), f"BUNDLE_DIGEST={digest}")
        sums = (bundle / "SHA256SUMS").read_text().splitlines()
        listed = {line[66:] for line in sums}
        present = {str(p.relative_to(bundle)) for p in bundle.rglob("*") if p.is_file()} - {"SHA256SUMS"}
        self.assertEqual(listed, present)
        self.assertEqual(sums, sorted(sums, key=lambda line: line[66:]))
        for required in (
            "install.sh", "bundle.env", "bundle.json", "releases.tsv", "images/images.tar",
            "cli/scripts/cheese", "cli/scripts/cheese-v2", "cli/v2/compose.yaml",
            "cli/v2/edge-forward.py", "cli/v2/verify-releases.py", "cli/install/cheese-env.sh",
            "payload/release-public-key.txt", "payload/models/manifest.json",
            "payload/releases/mcule-aa-in-stock/r2026-11-01/manifest.sig",
        ):
            self.assertIn(required, listed)
        meta = json.loads((bundle / "bundle.json").read_text())
        self.assertEqual(meta["images"]["backend"]["image_id"], BACKEND_ID)
        self.assertEqual(meta["releases"][0]["release_id"], "r2026-11-01")
        self.assertEqual(meta["bundle_version"], "pilot-1")
        self.assertEqual(meta["created_utc"], "2027-01-15T08:00:00Z")
        self.assertTrue(os.access(bundle / "install.sh", os.X_OK))
        self.assertFalse((self.tmp / "bundle.partial").exists())

    def test_producer_includes_sdk_wheelhouse(self):
        wheelhouse = self.tmp / "wheelhouse"
        wheelhouse.mkdir()
        (wheelhouse / "pkg-1.0-py3-none-any.whl").write_bytes(b"wheel")
        (wheelhouse / "requirements.lock").write_text("pkg==1.0\n")
        subprocess.run("sha256sum ./*.whl > SHA256SUMS", shell=True, cwd=wheelhouse, check=True)
        bundle, _ = self.build(self.payload(), extra=("--sdk-wheelhouse", wheelhouse))
        self.assertTrue((bundle / "sdk/wheelhouse/requirements.lock").is_file())
        self.assertIn("SDK_INCLUDED=true", (bundle / "bundle.env").read_text())

    def test_producer_rejects_bad_payloads(self):
        unsigned = self.payload("unsigned")
        next(unsigned.glob("releases/*/*/manifest.sig")).unlink()
        self.assertIn("manifest.sig", self.build(unsigned, "b1", check=False).stderr)

        two_keys = self.payload("two-keys")
        (two_keys / "release-public-key.txt").write_text(f"{self.key}\n{self.key}\n")
        self.assertIn("exactly one key", self.build(two_keys, "b2", check=False).stderr)

        not_ed25519 = self.payload("rsa", key=base64.b64encode(b"x" * 44).decode())
        self.assertIn("Ed25519", self.build(not_ed25519, "b3", check=False).stderr)

        two_releases = self.payload("two-rel")
        (two_releases / "releases/mcule-aa-in-stock/r2").mkdir()
        self.assertIn("exactly one release", self.build(two_releases, "b4", check=False).stderr)

        self.docker_state(images={"dmc/ui:test": UI_ID})
        self.assertIn("not present locally", self.build(self.payload("ok"), "b5", check=False).stderr)
        for name in ("b1", "b2", "b3", "b4", "b5"):
            self.assertFalse((self.tmp / name).exists())

    def test_producer_refuses_existing_output(self):
        (self.tmp / "bundle").mkdir()
        self.assertIn("already exists", self.build(self.payload(), check=False).stderr)

    # ── verification / trust ────────────────────────────────────────────────

    def test_verify_requires_and_checks_the_trusted_digest(self):
        bundle, digest = self.build(self.payload())
        cli = bundle / "cli/scripts/cheese-v2"
        self.run_cmd(cli, "verify", "--bundle", bundle, "--trusted-digest", digest)
        missing = self.run_cmd(cli, "verify", "--bundle", bundle, check=False)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("--trusted-digest", missing.stderr)
        wrong = self.run_cmd(cli, "verify", "--bundle", bundle, "--trusted-digest", "sha256:" + "0" * 64, check=False)
        self.assertNotEqual(wrong.returncode, 0)
        self.assertIn("does not match the trusted digest", wrong.stderr)
        untrusted = self.run_cmd(cli, "verify", "--bundle", bundle, "--allow-untrusted")
        self.assertIn("AUTHENTICITY IS NOT", untrusted.stderr)

    def test_verify_detects_tampering(self):
        bundle, digest = self.build(self.payload())
        cli = bundle / "cli/scripts/cheese-v2"
        target = next(bundle.glob("payload/releases/*/*/data.bin"))
        original = target.read_bytes()
        target.write_bytes(b"tampered" + original[8:])
        result = self.run_cmd(cli, "verify", "--bundle", bundle, "--trusted-digest", digest, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum verification FAILED", result.stderr)
        target.write_bytes(original)

        (bundle / "payload/extra.txt").write_text("smuggled")
        result = self.run_cmd(cli, "verify", "--bundle", bundle, "--trusted-digest", digest, check=False)
        self.assertIn("not covered by SHA256SUMS", result.stderr)
        (bundle / "payload/extra.txt").unlink()

        (bundle / "payload/link").symlink_to("/etc/passwd")
        result = self.run_cmd(cli, "verify", "--bundle", bundle, "--trusted-digest", digest, check=False)
        self.assertIn("symlinks or special files", result.stderr)
        (bundle / "payload/link").unlink()

        sums = bundle / "SHA256SUMS"
        sums.write_text(sums.read_text() + f"{'0' * 64}  ../outside\n")
        result = self.run_cmd(cli, "verify", "--bundle", bundle, "--allow-untrusted", check=False)
        self.assertIn("unsafe or malformed", result.stderr)

    # ── install / start / status / stop ──────────────────────────────────────

    def test_install_into_temp_home_then_start_status_stop(self):
        bundle, digest = self.build(self.payload())
        out = self.install(bundle, digest).stdout
        self.assertIn("installed in", out)

        # Layout, scoped tags and an empty secrets file (account-free runtime).
        short = digest[7:19]
        self.assertTrue((self.prefix / "bin/cheese").is_symlink())
        self.assertEqual(os.readlink(self.prefix / "current"), f"bundles/{short}")
        self.assertTrue((self.prefix / "data/releases/mcule-aa-in-stock/r2026-11-01/manifest.sig").is_file())
        secrets = self.prefix / "config/secrets.env"
        self.assertEqual(secrets.read_text(), "")
        self.assertEqual(stat.S_IMODE(secrets.stat().st_mode), 0o600)
        images = json.loads(self.state.read_text())["images"]
        self.assertEqual(images[f"cheese-v2/backend:{short}"], BACKEND_ID)
        self.assertEqual(images[f"cheese-v2/ui:{short}"], UI_ID)

        # The signature pre-check ran in the bundle's backend image, with no network.
        run = next(c for c in self.docker_calls() if c[0] == "run")
        self.assertIn("--network", run)
        self.assertEqual(run[run.index("--network") + 1], "none")
        self.assertIn(BACKEND_ID, run)

        ui_port, api_port = self.health_servers()
        started = self.cheese("start", "--timeout", "20").stdout
        self.assertIn(f"http://127.0.0.1:{ui_port}/", started)
        self.assertIn("readiness: ready", started)

        status = json.loads(self.cheese("status", "--json").stdout)
        self.assertEqual(status["bundle_digest"], digest)
        self.assertEqual(status["services"], {"backend": "running/healthy", "ui": "running/healthy", "edge": "running/healthy"})
        self.assertEqual(status["readiness"], "ready")
        self.assertIn("mcule-aa-in-stock / r2026-11-01", self.cheese("status").stdout)

        env = json.loads(self.state.read_text())["projects"][self.project()]["env"]
        self.assertEqual(
            json.loads(env["CHEESE_V2_LIBRARY_MANIFESTS_JSON"]),
            {"mcule-aa-in-stock": "/data/releases/mcule-aa-in-stock/r2026-11-01/manifest.json"},
        )
        model_sha = env["CHEESE_V2_MODEL_MANIFEST_SHA256"]
        self.assertEqual(env["CHEESE_V2_MODEL_ROOT"], f"/data/models/{model_sha}")
        self.assertTrue((self.prefix / "data/models" / model_sha / "manifest.json").is_file())
        self.assertEqual(env["CHEESE_V2_RELEASE_PUBLIC_KEY_B64"], self.key)

        self.cheese("start", "--timeout", "20")  # idempotent
        self.cheese("stop")
        self.assertFalse(json.loads(self.state.read_text())["projects"][self.project()]["running"])

        # Every compose call is scoped to this install's project; nothing is
        # ever removed beyond `compose down` (no -v, rm, prune or volume ops).
        for call in self.docker_calls():
            if call[0] == "compose" and call[1] != "version":
                self.assertEqual(call[call.index("-p") + 1], self.project())
            self.assertNotIn(call[0], ("rm", "rmi", "system", "volume", "network", "pull", "login"))
            self.assertNotIn("-v", call[1:] if call[0] == "compose" else [])
            self.assertNotIn("--volumes", call)

    def test_data_is_readable_by_the_container_user_under_strict_umask(self):
        bundle, digest = self.build(self.payload())
        self.run_cmd("bash", "-c", 'umask 077 && exec "$0" --trusted-digest "$1"', bundle / "install.sh", digest)
        for path in [self.prefix / "data", *(self.prefix / "data").rglob("*")]:
            mode = stat.S_IMODE(path.stat().st_mode)
            self.assertEqual(mode & 0o004, 0o004, f"{path} not world-readable ({oct(mode)})")
            if path.is_dir():
                self.assertEqual(mode & 0o001, 0o001, f"{path} not traversable")
        self.assertEqual(stat.S_IMODE((self.prefix / "config").stat().st_mode), 0o700)

    def test_verify_does_not_create_a_prefix(self):
        bundle, digest = self.build(self.payload())
        self.run_cmd(bundle / "cli/scripts/cheese-v2", "verify", "--bundle", bundle, "--trusted-digest", digest)
        self.assertFalse(self.prefix.exists())

    def test_reinstall_of_same_bundle_is_a_noop(self):
        bundle, digest = self.build(self.payload())
        self.install(bundle, digest)
        before = len(self.docker_calls())
        again = self.install(bundle, digest)
        self.assertIn("already installed", again.stdout)
        self.assertFalse([c for c in self.docker_calls()[before:] if c[0] in ("load", "tag", "run") or c[:2] == ["compose", "up"]])

    def test_images_already_present_are_not_reloaded(self):
        bundle, digest = self.build(self.payload())
        self.install(bundle, digest)
        self.assertFalse([c for c in self.docker_calls() if c[0] == "load"])

    def test_install_loads_images_when_missing(self):
        bundle, digest = self.build(self.payload())
        self.docker_state(images={})
        self.install(bundle, digest)
        self.assertTrue([c for c in self.docker_calls() if c[0] == "load"])

    def test_failed_signature_precheck_changes_nothing(self):
        bundle, digest = self.build(self.payload())
        self.docker_state(preflight_exit=1)
        result = self.install(bundle, digest, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature pre-check failed", result.stderr)
        self.assertFalse((self.prefix / "state/installed.env").exists())
        self.assertFalse((self.prefix / "current").exists())
        self.assertFalse((self.prefix / "data/releases").exists())

    def test_explicit_prefix_and_classic_cli_untouched(self):
        bundle, digest = self.build(self.payload())
        prefix = self.tmp / "opt cheese"  # spaces must survive
        self.install(bundle, digest, "--prefix", prefix)
        self.assertTrue((prefix / "state/installed.env").is_file())
        self.assertFalse(self.prefix.exists())
        self.assertFalse((self.home / ".config/cheese").exists())
        self.assertFalse((self.home / ".bashrc").exists())
        # The installed CLI finds its own prefix without --prefix.
        result = self.run_cmd(prefix / "bin/cheese", "v2", "status", "--json")
        self.assertEqual(json.loads(result.stdout)["prefix"], str(prefix))

    def test_classic_dispatcher_still_requires_classic_install(self):
        result = self.run_cmd(CHEESE, "doctor", check=False)
        self.assertIn(".config/cheese/cheese-env.sh", result.stderr)
        self.assertIn("v2 <command>", self.run_cmd(CHEESE, check=False).stdout)

    # ── update ───────────────────────────────────────────────────────────────

    def build_consistent_update(self, epoch=1_800_000_100, key=None):
        first, first_digest = self.build(self.payload("p1"), "bundle1")
        p2 = self.tmp / "p2"
        shutil.copytree(self.tmp / "p1", p2)
        release = p2 / "releases/vast-2026-h2/r1"
        release.mkdir(parents=True)
        (release / "manifest.json").write_text('{"database_id": "vast-2026-h2"}')
        (release / "manifest.sig").write_bytes(b"\x02" * 64)
        (p2 / "models/manifest.json").write_text('{"schema_version": 1, "files": {}, "v": 2}')
        if key:
            (p2 / "release-public-key.txt").write_text(key + "\n")
        second, second_digest = self.build(p2, "bundle2", epoch=epoch)
        return (first, first_digest), (second, second_digest)

    def test_update_adds_release_keeps_shared_data_and_is_idempotent(self):
        (b1, d1), (b2, d2) = self.build_consistent_update()
        self.install(b1, d1)
        staged = self.prefix / "data/releases/mcule-aa-in-stock/r2026-11-01/data.bin"
        inode = staged.stat().st_ino
        out = self.cheese("update", "--bundle", b2, "--trusted-digest", d2).stdout
        self.assertIn("Release mcule-aa-in-stock/r2026-11-01 already staged.", out)
        self.assertEqual(staged.stat().st_ino, inode)
        self.assertTrue((self.prefix / "data/releases/vast-2026-h2/r1/manifest.json").is_file())
        self.assertEqual(os.readlink(self.prefix / "current"), f"bundles/{d2[7:19]}")
        self.assertEqual(os.readlink(self.prefix / "previous"), f"bundles/{d1[7:19]}")
        self.assertIn("already installed", self.cheese("update", "--bundle", b2, "--trusted-digest", d2).stdout)

    def test_update_requires_existing_install(self):
        bundle, digest = self.build(self.payload())
        result = self.run_cmd(bundle / "cli/scripts/cheese-v2", "update", "--bundle", bundle, "--trusted-digest", digest, check=False)
        self.assertIn("nothing installed", result.stderr)

    def test_update_refuses_rotated_key_unless_accepted(self):
        other_dir = self.tmp / "other"
        other_dir.mkdir()
        new_key = ed25519_public_key_b64(other_dir)
        (b1, d1), (b2, d2) = self.build_consistent_update(key=new_key)
        self.install(b1, d1)
        refused = self.cheese("update", "--bundle", b2, "--trusted-digest", d2, check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("release signing key changed", refused.stderr)
        self.assertEqual(os.readlink(self.prefix / "current"), f"bundles/{d1[7:19]}")
        key_sha = subprocess.run(["sha256sum", b2 / "payload/release-public-key.txt"], capture_output=True, text=True).stdout[:64]
        self.cheese("update", "--bundle", b2, "--trusted-digest", d2, "--accept-release-key", f"sha256:{key_sha}")
        self.assertEqual(os.readlink(self.prefix / "current"), f"bundles/{d2[7:19]}")

    def test_update_refuses_downgrade_unless_allowed(self):
        (b1, d1), (b2, d2) = self.build_consistent_update(epoch=1_700_000_000)
        self.install(b1, d1)
        refused = self.cheese("update", "--bundle", b2, "--trusted-digest", d2, check=False)
        self.assertIn("older than the installed one", refused.stderr)
        self.cheese("update", "--bundle", b2, "--trusted-digest", d2, "--allow-downgrade")

    def test_update_refuses_mutated_release_id(self):
        b1, d1 = self.build(self.payload("p1"), "bundle1")
        b2, d2 = self.build(self.payload("p2"), "bundle2", epoch=1_800_000_100)  # same IDs, new bytes
        self.install(b1, d1)
        refused = self.cheese("update", "--bundle", b2, "--trusted-digest", d2, check=False)
        self.assertIn("release IDs must be immutable", refused.stderr)

    def test_update_of_running_stack_restarts_and_rolls_back_on_failure(self):
        (b1, d1), (b2, d2) = self.build_consistent_update()
        self.install(b1, d1)
        self.health_servers()
        self.cheese("start", "--timeout", "20")

        # Healthy new bundle: switched and restarted on the new images.
        self.cheese("update", "--bundle", b2, "--trusted-digest", d2, "--timeout", "20")
        project = json.loads(self.state.read_text())["projects"][self.project()]
        self.assertEqual(project["env"]["CHEESE_V2_BACKEND_IMAGE"], f"cheese-v2/backend:{d2[7:19]}")

        # A third bundle whose backend never turns healthy is rolled back.
        p3 = self.tmp / "p3"
        shutil.copytree(self.tmp / "p2", p3)
        bad_id = "sha256:" + "d" * 64
        self.docker_state(images={**json.loads(self.state.read_text())["images"], "dmc/backend:bad": bad_id})
        b3 = self.tmp / "bundle3"
        out = self.run_cmd(
            PRODUCER, "--backend-image", "dmc/backend:bad", "--ui-image", "dmc/ui:test",
            "--payload", p3, "--output", b3, env={"SOURCE_DATE_EPOCH": "1800000200"},
        ).stdout
        d3 = out.strip().splitlines()[-1].split("=", 1)[1]
        self.docker_state(unhealthy_images=[bad_id])
        failed = self.cheese("update", "--bundle", b3, "--trusted-digest", d3, "--timeout", "20", check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("rolling back", failed.stderr)
        self.assertEqual(os.readlink(self.prefix / "current"), f"bundles/{d2[7:19]}")
        self.assertEqual(os.readlink(self.prefix / "previous"), f"bundles/{d3[7:19]}")
        project = json.loads(self.state.read_text())["projects"][self.project()]
        self.assertTrue(project["running"])
        self.assertEqual(project["backend_id"], BACKEND_ID)
        self.assertEqual(json.loads(self.cheese("status", "--json").stdout)["bundle_digest"], d2)

    # ── compose rendering against the real docker compose parser ─────────────

    @unittest.skipUnless(REAL_DOCKER, "docker not available")
    def test_rendered_compose_matches_the_runtime_contract(self):
        bundle, digest = self.build(self.payload())
        self.install(bundle, digest)
        self.cheese("status")  # renders state/runtime.env
        config = json.loads(
            subprocess.run(
                [REAL_DOCKER, "compose", "-p", "contract-check", "-f", self.prefix / "current/cli/v2/compose.yaml",
                 "--env-file", self.prefix / "state/runtime.env", "config", "--format", "json"],
                check=True, capture_output=True, text=True,
            ).stdout
        )
        services = config["services"]
        backend, ui, edge = services["backend"]["environment"], services["ui"]["environment"], services["edge"]
        self.assertEqual(backend["ONPREM_SEARCH_ONLY"], "true")
        self.assertEqual(backend["ENVIRONMENT"], "production")
        self.assertEqual(json.loads(backend["LOCAL_LIBRARY_MANIFESTS_JSON"]),
                         {"mcule-aa-in-stock": "/data/releases/mcule-aa-in-stock/r2026-11-01/manifest.json"})
        self.assertEqual(backend["RELEASE_PUBLIC_KEY_B64"], self.key)
        self.assertRegex(backend["MODEL_MANIFEST_SHA256"], r"^[0-9a-f]{64}$")
        for absent in ("PLATFORM_API_KEYS", "PLATFORM_WORKER_API_KEY", "AUTH_DISABLED"):
            self.assertNotIn(absent, backend)
        self.assertEqual(ui["PLATFORM_API_URL"], "http://backend:8000")
        self.assertEqual(ui["VITE_ONPREM_SEARCH_ONLY"], "true")
        self.assertEqual(ui["PORT"], "3000")
        data_mount = next(v for v in services["backend"]["volumes"] if v["target"] == "/data")
        self.assertTrue(data_mount["read_only"])
        self.assertEqual(set(services["backend"]["networks"]), {"internal"})
        self.assertEqual(set(services["ui"]["networks"]), {"internal"})
        self.assertTrue(config["networks"]["internal"]["internal"])
        self.assertEqual(config["networks"]["hostonly"]["driver_opts"],
                         {"com.docker.network.bridge.enable_ip_masquerade": "false"})
        published = {(p["host_ip"], p["published"], p["target"]) for p in edge["ports"]}
        self.assertEqual(published, {("127.0.0.1", "18780", 18780), ("127.0.0.1", "18781", 18781)})
        self.assertNotIn("ports", services["backend"])
        self.assertNotIn("ports", services["ui"])
        for service in services.values():
            self.assertEqual(service["pull_policy"], "never")


class EdgeForwarderTest(unittest.TestCase):
    def test_forwards_http_to_target(self):
        upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Health)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            listen = probe.getsockname()[1]
        proc = subprocess.Popen(
            ["python3", "-I", REPO / "v2/edge-forward.py", f"{listen}=127.0.0.1:{upstream.server_address[1]}"],
            stdout=subprocess.PIPE, text=True,
        )
        self.addCleanup(proc.stdout.close)
        self.addCleanup(proc.wait, 10)
        self.addCleanup(proc.terminate)
        self.assertIn("->", proc.stdout.readline())
        with urllib.request.urlopen(f"http://127.0.0.1:{listen}/health/live", timeout=5) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(json.loads(response.read()), {"status": "ready"})


if __name__ == "__main__":
    unittest.main()
