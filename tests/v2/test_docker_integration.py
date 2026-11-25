"""Opt-in end-to-end test against real Docker (no CHEESE product stack).

Builds two stand-in images on top of a local backend image (so the real
release verifier and the real Python runtime are used), produces a bundle with
genuinely Ed25519-signed releases, installs it into a temporary HOME, starts
it, and checks the runtime contract and the network model from the host:

  - UI and API answer on loopback through the edge,
  - the UI reaches the backend as http://backend:8000,
  - backend, ui and edge cannot reach the internet,
  - releases are mounted read-only, contract env is exactly as specified,
  - a bad signature is rejected by the in-image pre-check.

Everything it creates (images tagged cheese-v2-it/*, cheese-v2/*:<digest>,
one compose project) is removed at the end; nothing else is touched.

    CHEESE_V2_IT_BASE_IMAGE=<local backend image> \
      python3 -m unittest tests/v2/test_docker_integration.py -v
"""

import base64
import json
import os
import shutil
import socket
import subprocess
import tempfile
import textwrap
import unittest
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = os.environ.get("CHEESE_V2_IT_BASE_IMAGE", "")

FAKE_SERVER = textwrap.dedent(
    """
    import json, os, socket, sys, urllib.request
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    ROLE, PORT = sys.argv[1], int(sys.argv[2])
    CONTRACT = ("ENVIRONMENT", "ONPREM_SEARCH_ONLY", "VITE_ONPREM_SEARCH_ONLY", "PLATFORM_API_URL",
                "LOCAL_LIBRARY_MANIFESTS_JSON", "MODEL_ROOT", "MODEL_MANIFEST_SHA256",
                "RELEASE_PUBLIC_KEY_B64", "PLATFORM_API_KEYS", "PLATFORM_API_KEY", "AUTH_DISABLED")

    def egress():
        try:
            socket.create_connection(("1.1.1.1", 443), 3).close()
            return True
        except OSError:
            return False

    def data_writable():
        try:
            open("/data/probe", "w").close()
            return True
        except OSError:
            return False

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path in ("/health", "/health/live", "/health/ready"):
                body = {"status": "ready", "role": ROLE}
            elif self.path == "/contract":
                body = {k: os.environ.get(k) for k in CONTRACT}
                body["data_writable"] = data_writable() if ROLE == "backend" else None
                body["manifests_exist"] = all(
                    os.path.isfile(p) for p in json.loads(os.environ.get("LOCAL_LIBRARY_MANIFESTS_JSON") or "{}").values())
                body["model_manifest_exists"] = os.path.isfile(os.path.join(os.environ.get("MODEL_ROOT") or "/x", "manifest.json"))
            elif self.path == "/egress":
                body = {"egress": egress()}
            elif self.path == "/via-backend":
                with urllib.request.urlopen(os.environ["PLATFORM_API_URL"] + "/health/live", timeout=5) as r:
                    body = json.loads(r.read())
            else:
                self.send_response(404); self.end_headers(); return
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
    """
)

# The UI healthcheck runs `node -e fetch(...)`; the stand-in has no Node.
NODE_SHIM = "#!/bin/sh\nexec python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:3000/health', timeout=5)\"\n"


def run(*args, check=True, **kwargs):
    kwargs.setdefault("text", True)
    return subprocess.run([str(a) for a in args], check=check, capture_output=True, **kwargs)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def get(url):
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.loads(response.read())


@unittest.skipUnless(BASE and shutil.which("docker"), "set CHEESE_V2_IT_BASE_IMAGE to a local backend image")
class DockerIntegrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="cheese-v2-it-"))
        cls.tags = []
        context = cls.tmp / "image"
        context.mkdir()
        (context / "fake_server.py").write_text(FAKE_SERVER)
        (context / "node").write_text(NODE_SHIM)
        for role, port in (("backend", 8000), ("ui", 3000)):
            tag = f"cheese-v2-it/{role}:test"
            (context / "Dockerfile").write_text(
                f"FROM {BASE}\nUSER root\nCOPY fake_server.py /opt/fake_server.py\n"
                # RUN chmod, not COPY --chmod: the test also has to build with Docker's legacy builder.
                f"COPY node /usr/local/bin/node\nRUN chmod 755 /usr/local/bin/node\nUSER 10001\n"
                f'ENTRYPOINT []\nCMD ["python", "-I", "/opt/fake_server.py", "{role}", "{port}"]\n'
            )
            run("docker", "build", "-q", "-t", tag, context, timeout=600)
            cls.tags.append(tag)

        # A payload with genuinely signed releases.
        cls.key_path = cls.tmp / "release.key"
        run("openssl", "genpkey", "-algorithm", "ed25519", "-out", cls.key_path)
        der = run("openssl", "pkey", "-in", cls.key_path, "-pubout", "-outform", "DER", text=False).stdout
        cls.payload = cls.tmp / "payload"
        for db, rel in (("mcule-aa-in-stock", "r1"), ("vast-2026-h2", "r7")):
            release = cls.payload / "releases" / db / rel
            release.mkdir(parents=True)
            (release / "manifest.json").write_text(json.dumps({"database_id": db, "release_id": rel}))
            run("openssl", "pkeyutl", "-sign", "-inkey", cls.key_path, "-rawin",
                "-in", release / "manifest.json", "-out", release / "manifest.sig")
        (cls.payload / "models").mkdir()
        (cls.payload / "models/manifest.json").write_text('{"schema_version": 1, "files": {}}')
        (cls.payload / "release-public-key.txt").write_text(base64.b64encode(der).decode() + "\n")

        cls.bundle = cls.tmp / "bundle"
        out = run(REPO / "v2/build-offline-bundle", "--backend-image", cls.tags[0], "--ui-image", cls.tags[1],
                  "--payload", cls.payload, "--output", cls.bundle, timeout=1200).stdout
        cls.digest = out.strip().splitlines()[-1].split("=", 1)[1]
        cls.short = cls.digest[7:19]
        cls.tags += [f"cheese-v2/backend:{cls.short}", f"cheese-v2/ui:{cls.short}"]
        # Drop the stand-in tags so install has to `docker load` them back.
        run("docker", "rmi", *cls.tags[:2])

        cls.home = cls.tmp / "home"
        cls.home.mkdir()
        cls.env = {**os.environ, "HOME": str(cls.home)}
        cls.prefix = cls.home / ".local/share/cheese-v2"
        install = run(cls.bundle / "install.sh", "--trusted-digest", cls.digest, env=cls.env, timeout=1200)
        cls.install_log = install.stdout + install.stderr
        cls.ui_port, cls.api_port = free_port(), free_port()
        (cls.prefix / "config/v2.conf").write_text(
            f"CHEESE_V2_BIND=127.0.0.1\nCHEESE_V2_UI_PORT={cls.ui_port}\nCHEESE_V2_API_PORT={cls.api_port}\n")
        cls.cheese = [str(cls.prefix / "bin/cheese"), "v2"]
        started = subprocess.run(cls.cheese + ["start", "--timeout", "180"], env=cls.env, capture_output=True, text=True)
        cls.start_log = started.stdout + started.stderr
        cls.project = dict(l.split("=", 1) for l in (cls.prefix / "state/installed.env").read_text().splitlines())["PROJECT"]
        if started.returncode != 0:
            cls.tearDownClass()
            raise AssertionError(f"start failed:\n{cls.start_log}")

    @classmethod
    def tearDownClass(cls):
        compose = cls.prefix / "current/cli/v2/compose.yaml"
        if compose.exists():
            run("docker", "compose", "-p", cls.project, "-f", compose,
                "--env-file", cls.prefix / "state/runtime.env", "down", "-v", "--remove-orphans", check=False)
        run("docker", "rmi", *cls.tags, check=False)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def container(self, service):
        return run("docker", "ps", "-q", "--filter", f"label=com.docker.compose.project={self.project}",
                   "--filter", f"label=com.docker.compose.service={service}").stdout.strip()

    def test_images_were_loaded_and_signatures_prechecked(self):
        self.assertIn("Loading images", self.install_log)
        self.assertIn("signature ok: /payload/releases/mcule-aa-in-stock/r1/manifest.json", self.install_log)
        self.assertIn("signature ok: /payload/releases/vast-2026-h2/r7/manifest.json", self.install_log)

    def test_host_reaches_ui_and_api_on_loopback(self):
        self.assertEqual(get(f"http://127.0.0.1:{self.ui_port}/health")["role"], "ui")
        self.assertEqual(get(f"http://127.0.0.1:{self.api_port}/health/live")["role"], "backend")
        status = json.loads(run(*self.cheese, "status", "--json", env=self.env).stdout)
        self.assertEqual(status["readiness"], "ready")
        published = run("docker", "port", self.container("edge")).stdout
        for line in published.splitlines():
            self.assertIn("127.0.0.1:", line)
        self.assertEqual(run("docker", "port", self.container("backend")).stdout.strip(), "")

    def test_ui_reaches_backend_by_service_name(self):
        self.assertEqual(get(f"http://127.0.0.1:{self.ui_port}/via-backend")["role"], "backend")

    def test_runtime_contract(self):
        backend = get(f"http://127.0.0.1:{self.api_port}/contract")
        self.assertEqual(backend["ONPREM_SEARCH_ONLY"], "true")
        self.assertEqual(backend["ENVIRONMENT"], "production")
        self.assertEqual(json.loads(backend["LOCAL_LIBRARY_MANIFESTS_JSON"]), {
            "mcule-aa-in-stock": "/data/releases/mcule-aa-in-stock/r1/manifest.json",
            "vast-2026-h2": "/data/releases/vast-2026-h2/r7/manifest.json",
        })
        self.assertTrue(backend["manifests_exist"])
        self.assertTrue(backend["model_manifest_exists"])
        self.assertFalse(backend["data_writable"])
        self.assertEqual(backend["RELEASE_PUBLIC_KEY_B64"],
                         (self.payload / "release-public-key.txt").read_text().strip())
        for absent in ("PLATFORM_API_KEYS", "PLATFORM_API_KEY", "AUTH_DISABLED"):
            self.assertIsNone(backend[absent])
        ui = get(f"http://127.0.0.1:{self.ui_port}/contract")
        self.assertEqual((ui["ONPREM_SEARCH_ONLY"], ui["VITE_ONPREM_SEARCH_ONLY"], ui["PLATFORM_API_URL"]),
                         ("true", "true", "http://backend:8000"))

    def test_no_internet_egress(self):
        self.assertFalse(get(f"http://127.0.0.1:{self.api_port}/egress")["egress"])
        self.assertFalse(get(f"http://127.0.0.1:{self.ui_port}/egress")["egress"])
        probe = "import socket\ntry:\n socket.create_connection(('1.1.1.1', 443), 3); print('OPEN')\nexcept OSError: print('BLOCKED')"
        self.assertEqual(run("docker", "exec", self.container("edge"), "python", "-c", probe).stdout.strip(), "BLOCKED")

    def test_bad_signature_is_rejected_in_image(self):
        tampered = self.tmp / "tampered/releases/x/r"
        tampered.mkdir(parents=True)
        shutil.copy(self.payload / "releases/vast-2026-h2/r7/manifest.json", tampered / "manifest.json")
        (tampered / "manifest.sig").write_bytes(b"\0" * 64)
        result = run("docker", "run", "--rm", "-i", "--network", "none", "-v", f"{tampered}:/r:ro",
                     "-e", "RELEASE_PUBLIC_KEY_B64=" + (self.payload / "release-public-key.txt").read_text().strip(),
                     "--entrypoint", "python", f"cheese-v2/backend:{self.short}", "-I", "-", "/r/manifest.json",
                     input=(REPO / "v2/verify-releases.py").read_text(), check=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("SIGNATURE FAILED", result.stderr)

    def test_zz_stop_removes_only_this_project_containers(self):
        run(*self.cheese, "stop", env=self.env)
        self.assertEqual(run("docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={self.project}").stdout.strip(), "")
        volumes = run("docker", "volume", "ls", "-q", "--filter", f"label=com.docker.compose.project={self.project}").stdout
        self.assertIn(f"{self.project}_cache", volumes)
        run(*self.cheese, "start", "--timeout", "180", env=self.env)  # restart works after stop
        self.assertEqual(get(f"http://127.0.0.1:{self.api_port}/health/live")["role"], "backend")


if __name__ == "__main__":
    unittest.main()
