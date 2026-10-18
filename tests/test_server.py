"""Integration tests for the Python standard-library admin server."""
import contextlib
import hashlib
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler
import json

SERVER = Path(__file__).resolve().parents[1] / "server" / "main.py"
# Some hosted macOS runners inherit an HTTP proxy. Loopback test traffic must
# never be routed through it (including macOS system proxy settings).
DIRECT_HTTP = build_opener(ProxyHandler({}))


def multipart(fields, filedata):
    boundary = "----TestPatchBoundary"
    payload = b""
    for key, value in fields.items():
        payload += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n{value}\r\n").encode()
    payload += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"payload.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n").encode()
    payload += filedata + f"\r\n--{boundary}--\r\n".encode()
    return payload, f"multipart/form-data; boundary={boundary}"


class TestServer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            cls.port = sock.getsockname()[1]
        cls.base = f"http://127.0.0.1:{cls.port}"
        env = dict(os.environ, ADMIN_PASSWORD="a-strong-test-password-123", COOKIE_SECURE="0", PORT=str(cls.port), HOST="127.0.0.1", DATA_DIR=cls.temp.name)
        env.update(NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
        cls.proc = subprocess.Popen([sys.executable, str(SERVER)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 30
        last_error = "not connected yet"
        while time.monotonic() < deadline:
            if cls.proc.poll() is not None:
                diagnostics = cls.proc.stderr.read().decode(errors="replace")
                cls.temp.cleanup()
                raise RuntimeError(f"Admin server exited (code {cls.proc.returncode}):\n{diagnostics}")
            try:
                with DIRECT_HTTP.open(cls.base + "/health", timeout=1) as res:
                    if res.status == 200:
                        return
                    last_error = f"/health returned HTTP {res.status}"
            except Exception as exc:
                last_error = f"{type(exc).__name__}: {exc}"
            time.sleep(0.2)
        cls.proc.terminate()
        try:
            _, stderr = cls.proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            cls.proc.kill()
            _, stderr = cls.proc.communicate(timeout=5)
        cls.temp.cleanup()
        raise RuntimeError(
            f"Server did not start at {cls.base}/health after 30 seconds. "
            f"Last HTTP error: {last_error}.\nServer output:\n{stderr.decode(errors='replace')}"
        )

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)
        cls.temp.cleanup()

    def request(self, path, data=None, method=None, headers=None):
        req = Request(self.base + path, data=data, method=method, headers=headers or {})
        try:
            res = DIRECT_HTTP.open(req, timeout=5)
            return res.status, res.headers, res.read()
        except HTTPError as e:
            return e.code, e.headers, e.read()

    def test_login_upload_update_and_restore_workflow_backend(self):
        code, _, raw = self.request("/api/patches?game=free_fire")
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(raw)["patches"], [])

        code, _, raw = self.request("/api/admin/patches", data=b"none")
        self.assertEqual(code, 401)

        code, headers, raw = self.request("/login", data=b"password=wrong")
        self.assertEqual(code, 403)
        password = b"password=a-strong-test-password-123"
        code, headers, raw = self.request("/login", data=password)
        self.assertEqual(code, 200)
        cookie = headers.get("Set-Cookie").split(";", 1)[0]
        code, _, admin_html = self.request("/admin", headers={"Cookie": cookie})
        self.assertEqual(code, 200)
        csrf = re.search(rb'csrf-token" content="([^"]+)', admin_html).group(1).decode()
        common = {"Cookie": cookie, "X-CSRF-Token": csrf}
        form = dict(game="free_fire", feature="Sample UI", version="1.0.0", target_name="sample.dat")
        orig = b"Test replacement payload; this is not game data."
        body, mime = multipart(form, orig)
        code, _, raw = self.request("/api/admin/patches", data=body, headers={"Cookie": cookie, "Content-Type": mime})
        self.assertEqual(code, 403)  # CSRF required
        code, _, raw = self.request("/api/admin/patches", data=body, headers={**common, "Content-Type": mime})
        self.assertEqual(code, 200, raw)
        patch_id = json.loads(raw)["id"]

        code, _, raw = self.request("/api/patches?game=free_fire")
        self.assertEqual(code, 200)
        data = json.loads(raw)["patches"]
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["sha256"], hashlib.sha256(orig).hexdigest())
        code, _, binary = self.request("/downloads/" + patch_id)
        self.assertEqual(code, 200)
        self.assertEqual(binary, orig)
        code, _, raw = self.request("/api/patches?game=free_fire_max")
        self.assertEqual(json.loads(raw)["patches"], [])

        next_bytes = b"Another harmless test payload."
        body, mime = multipart(dict(game="free_fire_max", feature="Sample UI", version="2.0.0", target_name="sample.dat"), next_bytes)
        code, _, raw = self.request("/api/admin/patches/"+patch_id, data=body, headers={**common, "Content-Type":mime})
        self.assertEqual(code, 200, raw)
        self.assertEqual(json.loads(self.request("/api/patches?game=free_fire")[2])["patches"], [])
        new_record = json.loads(self.request("/api/patches?game=free_fire_max")[2])["patches"][0]
        self.assertEqual(new_record["id"], patch_id)
        self.assertEqual(new_record["version"], "2.0.0")
        self.assertEqual(self.request("/downloads/"+patch_id)[2], next_bytes)

        # Admin can hide Patch from the public while retaining it for management.
        body, mime = multipart(dict(game="free_fire_max", feature="Sample UI", version="3.0.0", target_name="sample.dat", enabled="0", description="Hidden by admin", sort_order="7"), next_bytes)
        code, _, raw = self.request("/api/admin/patches/"+patch_id, data=body, headers={**common, "Content-Type": mime})
        self.assertEqual(code, 200, raw)
        self.assertEqual(json.loads(self.request("/api/patches?game=free_fire_max")[2])["patches"], [])
        code, _, raw = self.request("/api/admin/patches", headers=common)
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(raw)["patches"][0]["description"], "Hidden by admin")
        self.assertFalse(json.loads(raw)["patches"][0]["enabled"])

        code, _, raw = self.request("/api/admin/patches/"+patch_id, method="DELETE", headers=common)
        self.assertEqual(code, 200, raw)
        self.assertEqual(self.request("/downloads/"+patch_id)[0], 404)

    def test_admin_can_upload_3105_with_no_manual_target_name(self):
        from test_3105_codec import make_sample
        code, headers, _ = self.request("/login", data=b"password=a-strong-test-password-123")
        self.assertEqual(code, 200)
        cookie = headers.get("Set-Cookie").split(";", 1)[0]
        code, _, page = self.request("/admin", headers={"Cookie": cookie})
        csrf = re.search(rb'csrf-token" content="([^"]+)', page).group(1).decode()
        original, replacement = make_sample(password="test-secret")
        form = dict(game="free_fire", feature="3105 demo", version="1.0",
                    package_password="test-secret")
        body, mime = multipart(form, original)
        code, _, payload = self.request("/api/admin/patches", data=body,
            headers={"Cookie": cookie, "X-CSRF-Token": csrf, "Content-Type": mime})
        self.assertEqual(code, 200, payload)
        patch_id = json.loads(payload)["id"]
        response = json.loads(self.request("/api/patches?game=free_fire")[2])
        item = next(p for p in response["patches"] if p["id"] == patch_id)
        self.assertEqual(item["package_format"], "3105")
        self.assertIn("1 tệp", item["target_name"])
        code, _, binary = self.request("/downloads/"+patch_id)
        self.assertEqual(code, 200)
        import base64
        normalized = json.loads(binary)
        self.assertEqual(base64.b64decode(normalized["rules"][0]["replacement_data"]), replacement)
        self.assertEqual(hashlib.sha256(binary).hexdigest(), item["sha256"])
        code, _, _ = self.request("/api/admin/patches/" + patch_id, method="DELETE",
            headers={"Cookie": cookie, "X-CSRF-Token": csrf})
        self.assertEqual(code, 200)

    def test_edit_metadata_without_replacing_3105_bytes(self):
        code, headers, _ = self.request("/login", data=b"password=a-strong-test-password-123")
        self.assertEqual(code, 200)
        cookie = headers.get("Set-Cookie").split(";", 1)[0]
        code, _, page = self.request("/admin", headers={"Cookie": cookie})
        csrf = re.search(rb'csrf-token" content="([^"]+)', page).group(1).decode()
        common = {"Cookie": cookie, "X-CSRF-Token": csrf}
        raw_file = b"GooHan metadata test data"
        body, mime = multipart(dict(game="free_fire", feature="Old name", version="1.0", target_name="test.bin"), raw_file)
        code, _, result = self.request("/api/admin/patches", data=body,
            headers={**common, "Content-Type": mime})
        self.assertEqual(code, 200, result)
        patch_id = json.loads(result)["id"]
        patch_url = "/downloads/" + patch_id
        before = self.request(patch_url)[2]
        metadata = dict(game="free_fire", feature="New name", version="1.1",
                        description="Only Admin can modify metadata", sort_order=2, enabled=1)
        code, _, result = self.request("/api/admin/patches/" + patch_id + "/meta",
            data=json.dumps(metadata).encode(),
            headers={**common, "Content-Type": "application/json"})
        self.assertEqual(code, 200, result)
        after = json.loads(self.request("/api/patches?game=free_fire")[2])["patches"]
        item = next(p for p in after if p["id"] == patch_id)
        self.assertEqual(item["feature"], "New name")
        self.assertEqual(item["description"], "Only Admin can modify metadata")
        self.assertEqual(self.request(patch_url)[2], before)
        metadata["game"] = "free_fire_max"
        code, _, _ = self.request("/api/admin/patches/" + patch_id + "/meta",
            data=json.dumps(metadata).encode(), headers={**common, "Content-Type": "application/json"})
        self.assertEqual(code, 400)
        self.assertEqual(self.request("/api/admin/patches/" + patch_id,
            method="DELETE", headers=common)[0], 200)

    def test_admin_edit_app_content(self):
        code, _, raw = self.request("/api/config")
        self.assertEqual(code, 200)
        data = json.loads(raw)
        self.assertEqual(data["title"], "GooHan Patch")
        data["title"] = "Demo Patch App"
        data["accent_hex"] = "#00AA77"
        body = json.dumps(data).encode()
        code, _, raw = self.request("/api/admin/config", data=body, headers={"Content-Type": "application/json"})
        self.assertEqual(code, 401)  # Not logged in
        code, headers, _ = self.request("/login", data=b"password=a-strong-test-password-123")
        self.assertEqual(code, 200)
        cookie = headers.get("Set-Cookie").split(";", 1)[0]
        code, _, page = self.request("/admin", headers={"Cookie": cookie})
        csrf = re.search(rb'csrf-token" content="([^"]+)', page).group(1).decode()
        common = {"Content-Type": "application/json", "Cookie": cookie, "X-CSRF-Token": csrf}
        code, _, raw = self.request("/api/admin/config", data=body, headers=common)
        self.assertEqual(code, 200, raw)
        self.assertEqual(json.loads(self.request("/api/config")[2])["title"], "Demo Patch App")
        bad = dict(data, accent_hex="not-a-color")
        code, _, raw = self.request("/api/admin/config", data=json.dumps(bad).encode(), headers=common)
        self.assertEqual(code, 400)

    def test_reject_bad_data(self):
        code, _, raw = self.request("/api/patches?game=nope")
        self.assertEqual(code, 400)
        code, _, raw = self.request("/downloads/../../etc/passwd")
        self.assertEqual(code, 404)


if __name__ == "__main__":
    unittest.main()
