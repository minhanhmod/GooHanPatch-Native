#!/usr/bin/env python3
"""GooHan Patch admin, content settings and verified file distribution. Python 3.10+."""
import base64
import binascii
import hashlib
import plistlib
import hmac
import html
import json
import os
import re
import secrets
import sqlite3
import threading
import time
import uuid
from email.parser import BytesParser
from email.policy import default
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ROOT = Path(__file__).resolve().parent
DATA = Path(os.environ.get("DATA_DIR", ROOT / "data")).resolve()
DB = DATA / "patches.sqlite3"
FILES = DATA / "files"
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
LICENSE_API_TOKEN = os.environ.get("LICENSE_API_TOKEN", "")
PORT = int(os.environ.get("PORT", "8000"))
HOST = os.environ.get("HOST", "0.0.0.0")
COOKIE_SECURE = os.environ.get("COOKIE_SECURE", "1") != "0"
MAX_FILE = 50 * 1024 * 1024
SESSION_LIFETIME = 12 * 60 * 60
PATCH_MAGIC = b"3105PATCH\0"
GAME_BUNDLES = {"free_fire": "com.dts.freefireth", "free_fire_max": "com.dts.freefiremax"}
SESSIONS: dict[str, tuple[float, str]] = {}
LOGIN_ATTEMPTS: dict[str, list[float]] = {}
KEY_ATTEMPTS: dict[str, list[float]] = {}
LOCK = threading.RLock()
DEFAULT_CONFIG = {
    "title": "GooHan Patch",
    "kicker": "GOOHAN • PATCH MANAGER",
    "subtitle": "Quản lý các bản Patch đã được Admin phát hành",
    "notice": "Chỉ có thể thay thế tài liệu bạn được iOS cấp quyền truy cập. Không thể trực tiếp sửa thư mục riêng của Free Fire hoặc Free Fire MAX trên iOS không jailbreak.",
    "footer": "Bản sao lưu được giữ trên thiết bị cho đến khi khôi phục thành công.",
    "accent_hex": "#FF4554",
    "free_fire_name": "Free Fire",
    "free_fire_max_name": "Free Fire MAX",
    "apply_label": "Bật Patch",
    "restore_label": "Tắt & Khôi phục",
    "support_url": "",
    "section_label": "Thư viện Patch",
    "theme_label": "Chủ đề màu",
    "empty_title": "Chưa có gói Patch",
    "empty_subtitle": "Admin chưa phát hành gói cho danh mục này.",
    "navigation_title": "GOOHAN PATCH",
    "hero_tagline": "ONE-TOGGLE PATCH • BACKUP & RESTORE",
    "sync_title": "ĐỒNG BỘ TỪ ADMIN",
    "settings_title": "GooHan • Cài đặt",
    "server_label": "Địa chỉ máy chủ HTTPS",
    "sync_button_label": "Đồng bộ ngay",
}



def init_db():
    FILES.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("""CREATE TABLE IF NOT EXISTS patches (
            id TEXT PRIMARY KEY,
            game TEXT NOT NULL CHECK(game IN ('free_fire', 'free_fire_max')),
            feature TEXT NOT NULL, version TEXT NOT NULL,
            target_name TEXT NOT NULL, sha256 TEXT NOT NULL,
            size INTEGER NOT NULL, filename TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            sort_order INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1,
            package_format TEXT NOT NULL DEFAULT 'raw')""")
        columns = {r[1] for r in conn.execute("PRAGMA table_info(patches)")}
        for name, spec in (("description", "TEXT NOT NULL DEFAULT ''"),
                           ("sort_order", "INTEGER NOT NULL DEFAULT 0"),
                           ("enabled", "INTEGER NOT NULL DEFAULT 1"),
                           ("package_format", "TEXT NOT NULL DEFAULT 'raw'")):
            if name not in columns:
                conn.execute(f"ALTER TABLE patches ADD COLUMN {name} {spec}")
        conn.execute("CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        conn.execute("""CREATE TABLE IF NOT EXISTS license_keys (
            id TEXT PRIMARY KEY, key_hash TEXT NOT NULL UNIQUE, masked TEXT NOT NULL,
            prefix TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
            duration_seconds INTEGER NOT NULL, max_devices INTEGER NOT NULL,
            issued_at INTEGER NOT NULL, activated_at INTEGER, expires_at INTEGER,
            revoked INTEGER NOT NULL DEFAULT 0)""")
        conn.execute("""CREATE TABLE IF NOT EXISTS license_devices (
            license_id TEXT NOT NULL, device_hash TEXT NOT NULL,
            activated_at INTEGER NOT NULL,
            PRIMARY KEY (license_id, device_hash))""")
        conn.execute("""CREATE TABLE IF NOT EXISTS license_sessions (
            token_hash TEXT PRIMARY KEY, license_id TEXT NOT NULL,
            device_hash TEXT NOT NULL, issued_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL)""")
        conn.execute("CREATE INDEX IF NOT EXISTS license_sessions_key_idx ON license_sessions(license_id)")


def db():
    conn = sqlite3.connect(DB, timeout=20)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=20000")
    return conn


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def patch_to_public(row):
    return {
        "id": row["id"], "game": row["game"], "feature": row["feature"],
        "version": row["version"], "target_name": row["target_name"],
        "sha256": row["sha256"], "size": row["size"],
        "download_path": "/downloads/" + row["id"],
        "created_at": row["created_at"],
        "description": row["description"], "sort_order": row["sort_order"],
        "enabled": bool(row["enabled"]),
        "package_format": row["package_format"],
    }


def public_config():
    with db() as conn:
        stored = {r["key"]: r["value"] for r in conn.execute("SELECT key, value FROM config")}
    return {**DEFAULT_CONFIG, **stored}


def convert_3105(data: bytes, password: str, game: str) -> tuple[bytes, str]:
    """Validate/decrypt a 3105PATCH project and produce a checked multi-file plan.

    This is not a sandbox escape. The iOS app applies the plan only within an
    explicitly selected, writable folder from the document picker.
    """
    if not data.startswith(PATCH_MAGIC) or len(data) > MAX_FILE:
        raise ValueError("Không phải gói .3105 hợp lệ (thiếu header 3105PATCH)")
    try:
        env = plistlib.loads(data[len(PATCH_MAGIC):])
        version = env["schemaVersion"]
        package_id = str(uuid.UUID(env["packageID"])).upper()
        if version not in (1, 2):
            raise ValueError("Phiên bản .3105 không hỗ trợ")
        if env.get("isPasswordProtected"):
            if not password:
                raise ValueError("Gói .3105 được mã hóa: cần nhập mật khẩu của gói")
            if len(password.encode()) > 1024:
                raise ValueError("Mật khẩu gói quá dài")
            salt = env["kdfSalt"]
            rounds = env["kdfIterations"]
            wrapped = env["wrappedContentKey"]
            if len(salt) != 16 or not 100_000 <= rounds <= 1_000_000:
                raise ValueError("Thông số bảo vệ .3105 không hợp lệ")
            wrapping_key = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, rounds, 32)
            key_version = env.get("keyAADVersion") or version
            aad = f"3105PATCH/v{key_version}/key/{package_id}".encode()
            content_key = AESGCM(wrapping_key).decrypt(wrapped[:12], wrapped[12:], aad)
        else:
            content_key = env["publicContentKey"]
        if len(content_key) != 32 or not hmac.compare_digest(hashlib.sha256(content_key).digest(), env["keyFingerprint"]):
            raise ValueError("Khóa giải mã không đúng")
        blob = env["encryptedPayload"]
        decrypted = AESGCM(content_key).decrypt(blob[:12], blob[12:],
                           f"3105PATCH/v{version}/payload/{package_id}".encode())
        payload = plistlib.loads(decrypted)
        project = payload["project"]
        if str(uuid.UUID(project["id"])).upper() != package_id:
            raise ValueError("ID gói không khớp")
        # Directory declarations are validated as relative paths, but we do not
        # create directories; the chosen user-accessible folder must already
        # contain the target file structure before any bytes are replaced.
        for directory in project.get("directories", []):
            dp = directory["relativePath"]
            if directory["bundleID"] != GAME_BUNDLES[game] or not dp or dp.startswith("/") or "\\" in dp or any(x in ("", ".", "..") for x in dp.split("/")):
                raise ValueError("Khai báo thư mục trong gói không hợp lệ")
        rules = project["rules"]
        digests = payload["replacementDigests"]
        if not isinstance(rules, list) or not 1 <= len(rules) <= 100:
            raise ValueError("Gói phải có 1 đến 100 quy tắc thay thế")
        if len(digests) != len(rules):
            raise ValueError("Số lượng mã kiểm tra dữ liệu không khớp")
        allowed = GAME_BUNDLES[game]
        mapped, seen = [], set()
        for rule in rules:
            if rule["bundleID"] != allowed:
                raise ValueError(f"Gói nhắm tới {rule['bundleID']}, không đúng danh mục {game}")
            path = rule["relativePath"]
            parts = path.split("/")
            if (not path or len(path.encode()) > 4096 or path.startswith("/") or "\\" in path
                    or any(part in ("", ".", "..") for part in parts)
                    or any(ord(c) < 32 for c in path)):
                raise ValueError("Đường dẫn trong gói không an toàn")
            if path in seen:
                raise ValueError("Các quy tắc trong gói trùng đường dẫn")
            seen.add(path)
            replacement = rule["replacementData"]
            rule_id = str(uuid.UUID(rule["id"])).upper()
            if not hmac.compare_digest(hashlib.sha256(replacement).digest(), digests[rule_id]):
                raise ValueError("Dữ liệu quy tắc không khớp SHA-256")
            mapped.append({"relative_path": path, "replacement_data": base64.b64encode(replacement).decode("ascii")})
        result = {"format": "3105-project-v1", "package_id": package_id, "name": project["name"],
                  "game": game, "rules": mapped}
        binary = json_bytes(result)
        if len(binary) > 75 * 1024 * 1024:
            raise ValueError("Gói sau giải mã vượt giới hạn 75 MB")
        return binary, f"{len(mapped)} tệp từ .3105"
    except ValueError:
        raise
    except Exception as e:
        raise ValueError("Không thể giải mã/kiểm tra gói .3105; kiểm tra mật khẩu và định dạng") from e


# License codes are generated from a cryptographically secure 120-bit random suffix.
# Only SHA-256 digests are stored. Live sessions are scoped to a registered device,
# checked against expiry and revocation on *every* protected API request.
SESSION_SECONDS = 24 * 60 * 60

def license_digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def create_license_codes(prefix: str, days: int, hours: int, quantity: int,
                         max_devices: int, note: str = "") -> list[str]:
    prefix = prefix.strip().upper()
    if not re.fullmatch(r"[A-Z0-9](?:[A-Z0-9-]{0,22}[A-Z0-9])?", prefix):
        raise ValueError("Tiền tố chỉ gồm A-Z, 0-9, gạch nối (1–24 ký tự)")
    if not 0 <= days <= 3650 or not 0 <= hours <= 23 or days + hours == 0:
        raise ValueError("Thời hạn phải từ 1 giờ đến 3650 ngày 23 giờ")
    if not 1 <= quantity <= 100 or not 1 <= max_devices <= 10 or len(note) > 100:
        raise ValueError("Số key (1–100), số máy (1–10) hoặc ghi chú không hợp lệ")
    created = []
    now = int(time.time())
    with db() as conn:
        for _ in range(quantity):
            random_suffix = base64.b32encode(secrets.token_bytes(15)).decode("ascii").rstrip("=")
            code = f"{prefix}-{random_suffix[:6]}-{random_suffix[6:12]}-{random_suffix[12:18]}-{random_suffix[18:]}"
            conn.execute("""INSERT INTO license_keys
              (id,key_hash,masked,prefix,note,duration_seconds,max_devices,issued_at)
              VALUES (?,?,?,?,?,?,?,?)""",
              (uuid.uuid4().hex, license_digest(code), f"{prefix}-••••-{random_suffix[-6:]}",
               prefix, note, days*86400+hours*3600, max_devices, now))
            created.append(code)
        conn.commit()
    return created


def public_license(row):
    return dict(id=row["id"], masked=row["masked"], prefix=row["prefix"], note=row["note"],
                duration_seconds=row["duration_seconds"], max_devices=row["max_devices"],
                devices=row["devices"], issued_at=row["issued_at"],
                activated_at=row["activated_at"], expires_at=row["expires_at"],
                revoked=bool(row["revoked"]))


def activation_payload(row, token: str):
    return {"ok": True, "token": token, "expires_at": row["expires_at"],
            "server_time": int(time.time())}


def activate_license(key: str, device: str):
    key = key.strip().upper()
    if not 12 <= len(key) <= 100 or not re.fullmatch(r"[A-Z0-9-]+", key):
        raise ValueError("Key không hợp lệ")
    if not re.fullmatch(r"[a-f0-9]{32}", device):
        raise ValueError("Định danh thiết bị không hợp lệ")
    key_hash, device_hash = license_digest(key), license_digest(device)
    now = int(time.time())
    with db() as conn:
        # Immediate transactions serialize concurrent first-device activations.
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT * FROM license_keys WHERE key_hash=?", (key_hash,)).fetchone()
        if row is None or row["revoked"]:
            raise PermissionError("Key không tồn tại hoặc đã bị thu hồi")
        expires = row["expires_at"]
        if expires is not None and expires <= now:
            raise PermissionError("Key đã hết hạn")
        prior = conn.execute("SELECT 1 FROM license_devices WHERE license_id=? AND device_hash=?",
                             (row["id"],device_hash)).fetchone()
        if prior is None:
            count = conn.execute("SELECT COUNT(*) FROM license_devices WHERE license_id=?",(row["id"],)).fetchone()[0]
            if count >= row["max_devices"]:
                raise PermissionError("Key đã đạt số thiết bị tối đa")
            conn.execute("INSERT INTO license_devices VALUES (?,?,?)",(row["id"],device_hash,now))
        if expires is None:
            expires = now + row["duration_seconds"]
            conn.execute("UPDATE license_keys SET activated_at=?,expires_at=? WHERE id=?",
                         (now,expires,row["id"]))
        token = secrets.token_urlsafe(40)
        conn.execute("INSERT INTO license_sessions VALUES (?,?,?,?,?)",
                     (license_digest(token),row["id"],device_hash,now,min(expires,now+SESSION_SECONDS)))
        conn.execute("DELETE FROM license_sessions WHERE expires_at<=?",(now,))
        conn.commit()
    return {"ok":True,"token":token,"expires_at":expires,"server_time":now}


def check_license_token(header: str):
    if not header.startswith("Bearer ") or len(header) > 400:
        return None
    token = header[7:].strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{30,150}", token):
        return None
    now = int(time.time())
    with db() as conn:
        row = conn.execute("""SELECT k.id,k.expires_at,k.revoked,s.expires_at as session_expiry,
                 s.device_hash FROM license_sessions s
                 JOIN license_keys k ON k.id=s.license_id
                 JOIN license_devices d ON d.license_id=k.id AND d.device_hash=s.device_hash
                 WHERE s.token_hash=?""", (license_digest(token),)).fetchone()
    if row is None or row["revoked"] or row["expires_at"] is None:
        return None
    if row["expires_at"] <= now or row["session_expiry"] <= now:
        return None
    return {"license_id":row["id"],"expires_at":row["expires_at"],"server_time":now}


class RequestHandler(BaseHTTPRequestHandler):
    server_version = "GooHanPatch/2.0"

    def reply(self, status, content, mime="application/json; charset=utf-8", *, headers=None):
        if isinstance(content, (dict, list)):
            content = json_bytes(content)
        if isinstance(content, str):
            content = content.encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(content)

    def error_json(self, status, msg):
        self.reply(status, {"error": msg})

    def session(self):
        jar = SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie", ""))
        except Exception:
            return None
        item = jar.get("ogpatch_session")
        if item is None:
            return None
        with LOCK:
            session = SESSIONS.get(item.value)
            if session is None or session[0] < time.time():
                SESSIONS.pop(item.value, None)
                return None
            return session

    def require_admin(self):
        session = self.session()
        if not session:
            self.error_json(401, "Cần đăng nhập quản trị")
            return False
        if not hmac.compare_digest(self.headers.get("X-CSRF-Token", ""), session[1]):
            self.error_json(403, "CSRF token không hợp lệ")
            return False
        return True

    def require_license(self):
        status = check_license_token(self.headers.get("Authorization", ""))
        if status is None:
            self.error_json(401, "Key hết hạn, bị thu hồi hoặc phiên đăng nhập không hợp lệ")
        return status

    def read_json(self, limit=8192):
        if not self.headers.get("Content-Type", "").startswith("application/json"):
            raise ValueError("Cần Content-Type application/json")
        value = json.loads(self.read_body(limit))
        if not isinstance(value, dict):
            raise ValueError("Cần đối tượng JSON")
        return value

    def read_body(self, max_length=MAX_FILE + 262144):
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            raise ValueError("Content-Length không hợp lệ")
        if not 0 <= length <= max_length:
            raise ValueError("Dữ liệu vượt giới hạn hoặc thiếu Content-Length")
        return self.rfile.read(length)

    def get_form(self):
        content_type = self.headers.get("Content-Type", "")
        if not content_type.startswith("multipart/form-data;"):
            raise ValueError("Yêu cầu multipart/form-data")
        blob = self.read_body()
        message = BytesParser(policy=default).parsebytes(
            ("Content-Type: " + content_type + "\r\nMIME-Version: 1.0\r\n\r\n").encode() + blob
        )
        if not message.is_multipart():
            raise ValueError("Multipart không hợp lệ")
        form = {}
        for part in message.iter_parts():
            name = part.get_param("name", header="content-disposition")
            if not name or name in form:
                raise ValueError("Trường dữ liệu trùng hoặc thiếu")
            payload = part.get_payload(decode=True)
            if name == "file":
                if part.get_filename() is None or not payload:
                    raise ValueError("Chưa chọn tệp patch")
                if len(payload) > MAX_FILE:
                    raise ValueError("Tệp vượt quá 50 MB")
                form["file"] = payload
                form["upload_filename"] = part.get_filename()
            else:
                if len(payload) > 4096:
                    raise ValueError("Trường nhập quá dài")
                form[name] = payload.decode("utf-8", errors="strict").strip()
        return form

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/health":
            return self.reply(200, {"ok": True})
        if path == "/api/config":
            return self.reply(200, public_config())
        if path == "/api/license/status":
            status = self.require_license()
            if status is not None:
                return self.reply(200, {"ok": True, **status})
            return
        if path == "/api/admin/licenses":
            if not self.require_admin(): return
            with db() as conn:
                rows = conn.execute("""SELECT k.*,
                   (SELECT COUNT(*) FROM license_devices d WHERE d.license_id=k.id) AS devices
                   FROM license_keys k ORDER BY issued_at DESC LIMIT 2000""").fetchall()
            return self.reply(200,{"licenses":[public_license(r) for r in rows]})
        if path == "/api/admin/patches":
            if not self.require_admin():
                return
            with db() as conn:
                rows = conn.execute("SELECT * FROM patches ORDER BY sort_order, created_at DESC").fetchall()
            return self.reply(200, {"patches": [patch_to_public(r) for r in rows]})
        if path == "/api/patches":
            if not self.require_license(): return
            game = parse_qs(parsed.query).get("game", [""])[0]
            if game and game not in ("free_fire", "free_fire_max"):
                return self.error_json(400, "Game không hợp lệ")
            with db() as conn:
                if game:
                    rows = conn.execute("SELECT * FROM patches WHERE game=? AND enabled=1 ORDER BY sort_order, created_at DESC", (game,)).fetchall()
                else:
                    rows = conn.execute("SELECT * FROM patches WHERE enabled=1 ORDER BY sort_order, created_at DESC").fetchall()
            return self.reply(200, {"patches": [patch_to_public(r) for r in rows]})
        if path.startswith("/downloads/"):
            if not self.require_license(): return
            patch_id = path.removeprefix("/downloads/")
            if not re.fullmatch("[0-9a-f]{32}", patch_id):
                return self.error_json(404, "Không có tệp")
            with db() as conn:
                row = conn.execute("SELECT * FROM patches WHERE id=? AND enabled=1", (patch_id,)).fetchone()
            if row is None:
                return self.error_json(404, "Không tìm thấy")
            file = FILES / row["filename"]
            if not file.is_file():
                return self.error_json(404, "Tệp không tồn tại")
            return self.reply(200, file.read_bytes(), "application/octet-stream", headers={
                "Content-Disposition": 'attachment; filename="patch.bin"',
                "Cache-Control": "private, max-age=60"
            })
        if path == "/":
            return self.reply(302, b"", headers={"Location": "/admin"})
        if path == "/admin":
            session = self.session()
            if not session:
                return self.reply(200, LOGIN_HTML, "text/html; charset=utf-8")
            return self.reply(200, ADMIN_HTML.replace("__CSRF__", html.escape(session[1], quote=True)), "text/html; charset=utf-8")
        self.error_json(404, "Đường dẫn không tồn tại")

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/license/activate":
            try:
                data = self.read_json(4096)
                if set(data) != {"key", "device_id"}:
                    raise ValueError("Thiếu key hoặc mã thiết bị")
                key, device = data["key"], data["device_id"]
                if not isinstance(key,str) or not isinstance(device,str):
                    raise ValueError("Key hoặc mã thiết bị không hợp lệ")
                client = self.client_address[0]
                with LOCK:
                    recent = [t for t in KEY_ATTEMPTS.get(client,[]) if t > time.time()-900]
                    if len(recent)>=20:
                        return self.error_json(429,"Thử quá nhiều lần, chờ 15 phút")
                    KEY_ATTEMPTS[client] = recent
                response = activate_license(key,device)
                return self.reply(200,response)
            except (ValueError,UnicodeDecodeError,json.JSONDecodeError) as exc:
                with LOCK: KEY_ATTEMPTS.setdefault(self.client_address[0],[]).append(time.time())
                return self.error_json(400,str(exc))
            except PermissionError as exc:
                with LOCK: KEY_ATTEMPTS.setdefault(self.client_address[0],[]).append(time.time())
                return self.error_json(403,str(exc))
        if path == "/api/admin/licenses/auto":
            # Optional integration for bots/other admin services. Disabled unless
            # the admin sets a strong random token in ZCloudViet environment.
            candidate = self.headers.get("Authorization", "")
            if (len(LICENSE_API_TOKEN) < 32 or len(candidate) > 256 or
                not hmac.compare_digest(candidate, "Bearer " + LICENSE_API_TOKEN)):
                return self.error_json(403, "API token không hợp lệ")
            try:
                form = self.read_json(8192)
                if not set(form).issubset({"prefix","days","hours","quantity","max_devices","note"}):
                    raise ValueError("Trường không hợp lệ")
                codes = create_license_codes(str(form["prefix"]), int(form["days"]), int(form["hours"]),
                                             int(form.get("quantity",1)), int(form.get("max_devices",1)),
                                             str(form.get("note","")))
                return self.reply(200,{"ok":True,"keys":codes})
            except (ValueError,KeyError,TypeError) as exc:
                return self.error_json(400,str(exc))
        if path == "/api/admin/licenses":
            if not self.require_admin(): return
            try:
                form = self.read_json(8192)
                if not set(form).issubset({"prefix","days","hours","quantity","max_devices","note"}):
                    raise ValueError("Trường không hợp lệ")
                codes = create_license_codes(str(form["prefix"]),int(form["days"]),int(form["hours"]),
                                               int(form.get("quantity",1)),int(form.get("max_devices",1)),
                                               str(form.get("note","")))
                return self.reply(200,{"ok":True,"keys":codes,
                                       "info":"Hãy lưu key ngay; hệ thống chỉ lưu mã băm"})
            except (ValueError,KeyError,TypeError) as exc:
                return self.error_json(400,str(exc))
        if re.fullmatch(r"/api/admin/licenses/[0-9a-f]{32}/(revoke|reset-devices)",path):
            if not self.require_admin(): return
            license_id, action = path.split("/")[4:6]
            with db() as conn:
                if conn.execute("SELECT 1 FROM license_keys WHERE id=?",(license_id,)).fetchone() is None:
                    return self.error_json(404,"Không tìm thấy key")
                if action=="revoke":
                    conn.execute("UPDATE license_keys SET revoked=1 WHERE id=?",(license_id,))
                else:
                    conn.execute("DELETE FROM license_devices WHERE license_id=?",(license_id,))
                conn.execute("DELETE FROM license_sessions WHERE license_id=?",(license_id,))
                conn.commit()
            return self.reply(200,{"ok":True})
        if path == "/login":
            with LOCK:
                ip = self.client_address[0]
                recent = [t for t in LOGIN_ATTEMPTS.get(ip, []) if t > time.time() - 900]
                if len(recent) >= 10:
                    return self.error_json(429, "Quá nhiều lần đăng nhập")
                LOGIN_ATTEMPTS[ip] = recent
            try:
                body = self.read_body(8192)
                password = parse_qs(body.decode()).get("password", [""])[0]
            except (ValueError, UnicodeDecodeError):
                return self.error_json(400, "Yêu cầu không hợp lệ")
            if not hmac.compare_digest(password.encode(), ADMIN_PASSWORD.encode()):
                with LOCK:
                    LOGIN_ATTEMPTS[ip].append(time.time())
                return self.error_json(403, "Mật khẩu không chính xác")
            sid, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
            with LOCK:
                SESSIONS[sid] = (time.time() + SESSION_LIFETIME, csrf)
                LOGIN_ATTEMPTS.pop(ip, None)
            cookie = f"ogpatch_session={sid}; HttpOnly; SameSite=Lax; Path=/; Max-Age={SESSION_LIFETIME}"
            if COOKIE_SECURE:
                cookie += "; Secure"
            return self.reply(200, {"ok": True}, headers={"Set-Cookie": cookie})
        if path == "/api/admin/config":
            if not self.require_admin():
                return
            if not self.headers.get("Content-Type", "").startswith("application/json"):
                return self.error_json(415, "Yêu cầu JSON")
            try:
                settings = json.loads(self.read_body(16384))
                if not isinstance(settings, dict) or set(settings) != set(DEFAULT_CONFIG):
                    raise ValueError("Thiếu hoặc thừa trường cấu hình")
                for key, value in settings.items():
                    if not isinstance(value, str) or len(value) > 1200:
                        raise ValueError("Giá trị cấu hình không hợp lệ: " + key)
                if not re.fullmatch(r"#[0-9a-fA-F]{6}", settings["accent_hex"]):
                    raise ValueError("Màu cần có dạng #FF4554")
                if settings["support_url"] and not re.fullmatch(r"https://[^\s]+", settings["support_url"]):
                    raise ValueError("Link hỗ trợ phải dùng HTTPS")
                if not settings["title"].strip():
                    raise ValueError("Tên hiển thị không được để trống")
            except (ValueError, UnicodeDecodeError) as exc:
                return self.error_json(400, str(exc))
            with db() as conn:
                conn.executemany("INSERT OR REPLACE INTO config(key,value) VALUES(?,?)", settings.items())
                conn.commit()
            return self.reply(200, {"ok": True})
        if path == "/api/admin/logout":
            if not self.require_admin():
                return
            cookie = self.headers.get("Cookie", "")
            jar = SimpleCookie()
            try:
                jar.load(cookie)
                if "ogpatch_session" in jar:
                    with LOCK:
                        SESSIONS.pop(jar["ogpatch_session"].value, None)
            except Exception:
                pass
            return self.reply(200, {"ok": True}, headers={
                "Set-Cookie": "ogpatch_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
            })
        # Edit labels and publishing state without re-uploading a .3105 package.
        if re.fullmatch(r"/api/admin/patches/[0-9a-f]{32}/meta", path):
            if not self.require_admin():
                return
            if not self.headers.get("Content-Type", "").startswith("application/json"):
                return self.error_json(415, "Cần dữ liệu JSON")
            try:
                body = json.loads(self.read_body(8192))
                fields = {"feature", "version", "description", "sort_order", "enabled", "game"}
                if not isinstance(body, dict) or set(body) != fields:
                    raise ValueError("Thiếu trường cập nhật")
                feature, version, description = body["feature"], body["version"], body["description"]
                order, enabled, game = int(body["sort_order"]), int(body["enabled"]), body["game"]
                if not (isinstance(feature, str) and 1 <= len(feature) <= 80 and
                        isinstance(version, str) and 1 <= len(version) <= 32 and
                        isinstance(description, str) and len(description) <= 280 and
                        -10000 <= order <= 10000 and enabled in (0, 1)):
                    raise ValueError("Trường cập nhật không hợp lệ")
            except (ValueError, TypeError) as exc:
                return self.error_json(400, str(exc))
            patch_id = path.split("/")[4]
            with db() as conn:
                old = conn.execute("SELECT game FROM patches WHERE id=?", (patch_id,)).fetchone()
                if old is None:
                    return self.error_json(404, "Gói không còn tồn tại")
                if old["game"] != game:
                    return self.error_json(400, "Đổi danh mục cần tải lại file .3105 đúng game")
                conn.execute("UPDATE patches SET feature=?,version=?,description=?,sort_order=?,enabled=? WHERE id=?",
                             (feature, version, description, order, enabled, patch_id))
                conn.commit()
            return self.reply(200, {"ok": True, "id": patch_id})
        if path == "/api/admin/patches" or re.fullmatch(r"/api/admin/patches/[0-9a-f]{32}", path):
            if not self.require_admin():
                return
            updating_id = path.rsplit("/", 1)[-1] if path != "/api/admin/patches" else None
            try:
                form = self.get_form()
                game = form.get("game", "")
                feature = form.get("feature", "")
                version = form.get("version", "")
                target = form.get("target_name", "")
                payload = form.get("file", b"")
                description = form.get("description", "")
                sort_order = int(form.get("sort_order", "0"))
                enabled = int(form.get("enabled", "1"))
                if len(description) > 280 or sort_order not in range(-10000, 10001) or enabled not in (0, 1):
                    raise ValueError("Mô tả, thứ tự hoặc trạng thái không hợp lệ")
                if game not in ("free_fire", "free_fire_max"):
                    raise ValueError("Phải chọn Free Fire hoặc Free Fire MAX")
                if not (1 <= len(feature) <= 80 and 1 <= len(version) <= 32):
                    raise ValueError("Tên chức năng hoặc phiên bản không hợp lệ")
                if not payload:
                    raise ValueError("Cần tải tệp patch lên")
                uploaded_name = form.get("upload_filename", "")
                is_3105 = uploaded_name.lower().endswith(".3105") or payload.startswith(PATCH_MAGIC)
                if is_3105:
                    package_format = "3105"
                    payload, target = convert_3105(payload, form.get("package_password", ""), game)
                else:
                    package_format = "raw"
                    if not (1 <= len(target) <= 128 and re.fullmatch(r"[a-zA-Z0-9_.() -]+", target)):
                        raise ValueError("Tên tệp đích chỉ được là tên tệp, không chứa đường dẫn")
                    if target in (".", "..") or target.startswith("."):
                        raise ValueError("Tên tệp không hợp lệ")
            except (ValueError, UnicodeDecodeError) as exc:
                return self.error_json(400, str(exc))
            patch_id = updating_id or uuid.uuid4().hex
            filename = uuid.uuid4().hex + ".bin"
            outfile = FILES / filename
            outfile.write_bytes(payload)
            old_filename = None
            try:
                with db() as conn:
                    if updating_id:
                        old = conn.execute("SELECT filename FROM patches WHERE id=?", (patch_id,)).fetchone()
                        if not old:
                            outfile.unlink(missing_ok=True)
                            return self.error_json(404, "Patch không tồn tại")
                        old_filename = old["filename"]
                        conn.execute("""UPDATE patches SET game=?, feature=?, version=?, target_name=?,
                            sha256=?,size=?,filename=?,created_at=?,description=?,sort_order=?,enabled=?,package_format=? WHERE id=?""", (
                            game, feature, version, target, hashlib.sha256(payload).hexdigest(),
                            len(payload), filename, int(time.time()), description, sort_order, enabled, package_format, patch_id))
                    else:
                        conn.execute("""INSERT INTO patches (id,game,feature,version,target_name,sha256,size,filename,created_at,description,sort_order,enabled,package_format) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""", (
                            patch_id, game, feature, version, target, hashlib.sha256(payload).hexdigest(),
                            len(payload), filename, int(time.time()), description, sort_order, enabled, package_format))
                    conn.commit()
            except Exception:
                outfile.unlink(missing_ok=True)
                raise
            if old_filename:
                (FILES / old_filename).unlink(missing_ok=True)
            return self.reply(200, {"ok": True, "id": patch_id})
        self.error_json(404, "Đường dẫn không tồn tại")

    def do_DELETE(self):
        path = urlparse(self.path).path
        if not re.fullmatch(r"/api/admin/patches/[0-9a-f]{32}", path):
            return self.error_json(404, "Không tìm thấy")
        if not self.require_admin():
            return
        patch_id = path.rsplit("/", 1)[-1]
        with db() as conn:
            row = conn.execute("SELECT filename FROM patches WHERE id=?", (patch_id,)).fetchone()
            if row is None:
                return self.error_json(404, "Không tìm thấy")
            conn.execute("DELETE FROM patches WHERE id=?", (patch_id,))
            conn.commit()
        (FILES / row["filename"]).unlink(missing_ok=True)
        self.reply(200, {"ok": True})


STYLE = """
:root{color-scheme:dark;--bg:#080d17;--surface:#101a2a;--edge:#253348;--text:#edf2fa;--muted:#98a9bf;--accent:#ff4554}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background-color:var(--bg);background-image:linear-gradient(#ffffff08 1px,transparent 1px),linear-gradient(90deg,#ffffff08 1px,transparent 1px),radial-gradient(ellipse at 90% 2%,#fc465024,transparent 45%);background-size:28px 28px,28px 28px,100% 100%;color:var(--text);font-family:Inter,-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;min-height:100vh}
main{max-width:1160px;margin:0 auto;padding:34px 22px 72px}header{display:flex;align-items:center;justify-content:space-between;gap:15px;flex-wrap:wrap;padding:0 0 25px}header .brand{font-size:25px}.brand{font-weight:900;letter-spacing:-.6px;color:var(--text)}.brand b{color:var(--accent)}.tag{font-size:11px;text-transform:uppercase;letter-spacing:1.8px;color:var(--accent);font-weight:800;margin-bottom:9px;display:block}.muted{color:var(--muted);font-size:13px;line-height:1.6}
.panel{background:linear-gradient(145deg,#142032f5,#0d1626f7);border:1px solid var(--edge);box-shadow:0 16px 60px #0004;border-radius:20px;padding:25px;margin-bottom:20px}h2{margin:0 0 15px;font-size:19px;letter-spacing:-.2px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:17px}label{display:block;font-weight:600;font-size:12px;color:#dce5f2;margin:0 0 8px}input,select,textarea{width:100%;background:#080f1d;border:1px solid #2c3a50;color:var(--text);border-radius:12px;padding:13px;outline:0;font:inherit;font-size:14px;transition:border .16s}input:focus,select:focus,textarea:focus{border-color:var(--accent)}input[type=file]{padding:10px}textarea{min-height:95px;resize:vertical}button{border:0;border-radius:11px;background:var(--accent);color:#101018;font-size:13px;font-weight:800;padding:12px 18px;cursor:pointer;transition:transform .13s,opacity .15s}button:hover{transform:translateY(-1px)}button:disabled{opacity:.45;cursor:wait}button.secondary{background:#253448;color:#f4f7ff}button.danger{background:#57313e;color:#ffccd3}.row{display:flex;justify-content:space-between;align-items:center;gap:13px;flex-wrap:wrap}.card{padding:18px 0;border-bottom:1px solid var(--edge)}.card:last-child{border-bottom:0}.pill{display:inline-block;background:#20384b;color:#9bdbd5;font-size:10px;font-weight:800;padding:5px 9px;border-radius:99px}.notice{border:1px solid #624250;border-radius:14px;background:#2c1728cc;color:#f9c7d3;padding:16px 18px;line-height:1.6;font-size:13px;margin:0 0 22px}.small{font-size:12px;color:#8b9fb7;line-height:1.7;overflow-wrap:anywhere}#msg,#configmsg{min-height:19px;color:#8cf4c4}#fields{margin-bottom:15px}.palette{display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:9px;margin:12px 0 20px}.swatch{aspect-ratio:1;border-radius:99px;border:3px solid #172133;cursor:pointer;max-width:38px;width:100%;padding:0}.swatch.selected{outline:2px solid white;outline-offset:2px}section .subtitle{margin:-4px 0 17px}.countBox{background:#0e1b2d;border:1px solid var(--edge);padding:10px 14px;border-radius:12px;font-size:12px;color:var(--muted)}.heroStrip{margin-bottom:21px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}.mono{font-family:ui-monospace,Consolas,monospace}
@media(max-width:640px){main{padding:23px 12px 58px}.panel{padding:17px}.grid{grid-template-columns:1fr}.palette{grid-template-columns:repeat(8,1fr)}header .brand{font-size:22px}button{padding:11px 13px}}
"""

LOGIN_HTML = """<!doctype html><html lang=\"vi\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>GooHan Patch Admin</title><style>""" + STYLE + """</style></head><body><main style=\"max-width:480px;margin-top:10vh\"><div class=\"brand\">GooHan <b>Patch</b> Admin</div><p class=\"muted\">Đăng nhập để quản lý các gói tập tin.</p><div class=\"panel\"><form id=\"login\"><label>Mật khẩu quản trị</label><input name=\"password\" type=\"password\" required autocomplete=\"current-password\"><p><button>Đăng nhập</button></p><div id=\"msg\"></div></form></div></main><script>
document.getElementById('login').onsubmit=async e=>{e.preventDefault();const btn=e.target.querySelector('button');btn.disabled=true;let res=await fetch('/login',{method:'POST',body:new URLSearchParams(new FormData(e.target))});let j=await res.json();document.getElementById('msg').textContent=j.error||'';btn.disabled=false;if(j.ok)location.replace('/admin')};
</script></body></html>"""

ADMIN_HTML = """<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="csrf-token" content="__CSRF__"><title>GooHan Patch Admin</title><style>""" + STYLE + """</style></head><body><main>
<header><div><span class="tag">CONTROL CENTER / VERSION 5</span><div class="brand">GooHan <b>Patch</b> Admin</div><div class="muted">Quản lý xuất bản và nội dung • Đồng bộ trực tiếp với iPhone</div></div><button class="secondary" id="logout">Đăng xuất ↗</button></header>
<div class="heroStrip"><div class="countBox" id="totalCount">Tổng: — gói</div><div class="countBox" id="liveCount">Đang xuất bản: —</div><div class="countBox">Trạng thái: <span style="color:#8cf4c4">● LIVE</span></div></div>
<div class="notice"><b>Giới hạn iOS:</b> Ứng dụng không jailbreak không thể tự dò tìm hoặc thay thế tệp trong vùng dữ liệu riêng của Free Fire hay Free Fire MAX.</div>
<section class="panel"><span class="tag">01 / BRANDING</span><h2>Tùy chỉnh nội dung ứng dụng</h2><p class="muted subtitle">Đổi tiêu đề, mô tả, nội dung cảnh báo, tên danh mục và màu mặc định. Mỗi iPhone vẫn có thể chọn riêng một trong 24 màu.</p><div class="palette" id="palette"></div><form id="settings"><div class="grid" id="fields"></div><p class="row"><span class="small">Các nội dung cập nhật khi app tải lại cấu hình. Tên dưới icon, icon, quyền iOS và bố cục SwiftUI cần build IPA mới.</span><button>Lưu nội dung</button></p><div class="small" id="configmsg"></div></form></section>
<section class="panel"><span class="tag">02 / PATCH PUBLISHER</span><h2 id="formtitle">Đăng gói Patch mới (.3105 hoặc tệp đơn)</h2><p class="muted">Upload trực tiếp gói <b>.3105</b>. Máy chủ đọc các quy tắc trong gói; nếu được mã hóa, điền mật khẩu bên dưới. Không cần nhập tên tệp đích với .3105. Gói chỉ áp dụng trong thư mục mà iOS cho phép người dùng chọn.</p><form id="form"><div class="grid"><div><label>Danh mục</label><select name="game"><option value="free_fire">Free Fire</option><option value="free_fire_max">Free Fire MAX</option></select></div><div><label>Tên chức năng</label><input name="feature" maxlength="80" required></div><div><label>Phiên bản</label><input name="version" maxlength="32" value="1.0" required></div><div><label>Tên tệp đích (chỉ cần cho file đơn, bỏ trống khi dùng .3105)</label><input name="target_name" maxlength="128" placeholder="sample.dat"></div><div><label>Mô tả</label><input name="description" maxlength="280"></div><div><label>Thứ tự (thấp hiển thị trước)</label><input name="sort_order" type="number" min="-10000" max="10000" value="0" required></div><div><label>Xuất bản</label><select name="enabled"><option value="1">Hiển thị</option><option value="0">Ẩn</option></select></div><div><label>Gói .3105 hoặc tệp đơn (tối đa 50 MB)</label><input name="file" type="file" accept=".3105,.bin,.dat,.plist,.json,*/*" required></div><div><label>Mật khẩu của gói .3105 (nếu có, không lưu trên server)</label><input type="password" name="package_password" autocomplete="off" placeholder="Chỉ cần khi gói bị mã hóa"></div></div><p class="row"><span class="small">SHA-256 kiểm tra tính toàn vẹn khi app tải file.</span><span><button type="button" class="secondary" id="cancel" hidden>Hủy sửa</button> <button id="submit">Lưu Patch</button></span></p><div id="msg" class="small"></div></form></section>
<section class="panel"><span class="tag">03 / LIBRARY</span><div class="row"><h2>Gói Patch đã tạo</h2><button class="secondary" id="refresh">Làm mới</button></div><div id="list" class="muted"></div></section>
</main><script>
const csrf=document.querySelector('meta[name="csrf-token"]').content;
const configFields={title:'Tên hiển thị trong ứng dụng',kicker:'Chữ nhỏ đầu trang',subtitle:'Mô tả ở trang chính',notice:'Thông báo quan trọng',footer:'Nội dung chân trang',accent_hex:'Màu chủ đạo (#RRGGBB)',free_fire_name:'Tên danh mục Free Fire',free_fire_max_name:'Tên danh mục Free Fire MAX',apply_label:'Nhãn bật Patch',restore_label:'Nhãn tắt Patch',support_url:'Link hỗ trợ (HTTPS)',section_label:'Tiêu đề khu vực thư viện',theme_label:'Tiêu đề trang chọn màu',empty_title:'Tiêu đề danh sách trống',empty_subtitle:'Mô tả danh sách trống',navigation_title:'Chữ trên thanh điều hướng',hero_tagline:'Khẩu hiệu ở đầu trang',sync_title:'Tiêu đề ô đồng bộ',settings_title:'Tên màn hình Cài đặt',server_label:'Nhãn địa chỉ máy chủ',sync_button_label:'Tên nút đồng bộ trong Cài đặt'};
const form=document.getElementById('form'),msg=document.getElementById('msg');let editing=null,patches=[];
const colors=['#FF4554','#DC2747','#FF589C','#F78CBF','#FF756A','#FF9248','#F5AE37','#F5D54A','#BEDC4C','#54D96C','#1DCB82','#73E4BA','#36C2B1','#43D5E8','#68BDF6','#438CF5','#566CF3','#7371F6','#A36AF6','#C394FC','#D06ED3','#C99162','#9BAABD','#E3EBFA'];
const palette=document.getElementById('palette');for(const hex of colors){const b=document.createElement('button');b.type='button';b.className='swatch';b.style.background=hex;b.dataset.hex=hex;b.title=hex;b.setAttribute('aria-label','Chọn màu '+hex);b.onclick=()=>{const field=document.querySelector('[name="accent_hex"]');if(field){field.value=hex;palette.querySelectorAll('.swatch').forEach(v=>v.classList.toggle('selected',v===b))}};palette.append(b)}
function elem(tag,content,cls){const el=document.createElement(tag);el.textContent=content||'';if(cls)el.className=cls;return el}
async function asJSON(url,options){const r=await fetch(url,options);const j=await r.json();if(!r.ok)throw Error(j.error||'Lỗi máy chủ');return j}
async function loadSettings(){const c=await asJSON('/api/config');const root=document.getElementById('fields');root.replaceChildren();for(const [k,label] of Object.entries(configFields)){const wrap=elem('div'),lab=elem('label',label),field=document.createElement(k==='notice'||k==='subtitle'?'textarea':'input');field.name=k;field.value=c[k]||'';field.maxLength=1200;field.style.width='100%';field.style.background='#0e131c';field.style.color='#fff';field.style.border='1px solid #3a4458';field.style.borderRadius='10px';field.style.padding='12px';wrap.append(lab,field);root.append(wrap)}document.getElementById('palette').querySelectorAll('.swatch').forEach(b=>b.classList.toggle('selected',b.dataset.hex.toLowerCase()===c.accent_hex.toLowerCase()))}
document.getElementById('settings').onsubmit=async e=>{e.preventDefault();const data=Object.fromEntries(new FormData(e.target));const el=document.getElementById('configmsg');try{await asJSON('/api/admin/config',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify(data)});el.textContent='Đã lưu nội dung. Mở lại ứng dụng hoặc làm mới để cập nhật.'}catch(err){el.textContent=err.message}};
async function refresh(){try{const j=await asJSON('/api/admin/patches',{headers:{'X-CSRF-Token':csrf}});patches=j.patches||[];document.getElementById('totalCount').textContent='Tổng: '+patches.length+' gói';document.getElementById('liveCount').textContent='Đang xuất bản: '+patches.filter(p=>p.enabled).length;const root=document.getElementById('list');root.replaceChildren();if(!patches.length){root.textContent='Chưa có gói Patch nào.';return}for(const p of patches){const card=elem('div','','card'),header=elem('div','','row'),left=elem('div');left.append(elem('strong',p.feature),document.createTextNode('  '),elem('span',p.enabled?'Đang hiển thị':'Đang ẩn','pill'));
left.append(elem('div',(p.game==='free_fire'?'Free Fire':'Free Fire MAX')+' · v'+p.version+' · '+p.target_name+' · '+(p.size/1024).toFixed(1)+' KB · '+(p.package_format==='3105'?'gói .3105':'tệp đơn'),'muted'),elem('div',p.description||'','small'),elem('div','SHA-256: '+p.sha256,'small'));
const buttons=elem('div');const edit=elem('button','Sửa','secondary');edit.onclick=()=>{editing=p.id;for(const k of ['game','feature','version','target_name','description','sort_order','enabled'])form.elements[k].value=p[k]??'';form.elements.file.value='';form.elements.file.required=false;document.getElementById('formtitle').textContent='Cập nhật gói Patch';document.getElementById('cancel').hidden=false;msg.textContent='Có thể chỉ sửa tên/mô tả/trạng thái mà không cần tải lại file. Muốn đổi danh mục cần tải lại file.';window.scrollTo({top:0,behavior:'smooth'})};
const del=elem('button','Xóa','danger');del.onclick=async()=>{if(!confirm('Xóa gói '+p.feature+'?'))return;try{await asJSON('/api/admin/patches/'+p.id,{method:'DELETE',headers:{'X-CSRF-Token':csrf}});await refresh()}catch(err){alert(err.message)}};buttons.append(edit,document.createTextNode(' '),del);header.append(left,buttons);card.append(header);root.append(card)}}catch(err){document.getElementById('list').textContent=err.message}}
function reset(){editing=null;form.reset();form.elements.file.required=true;document.getElementById('cancel').hidden=true;document.getElementById('formtitle').textContent='Đăng gói Patch mới (.3105 hoặc tệp đơn)';msg.textContent=''}
document.getElementById('cancel').onclick=reset;document.getElementById('refresh').onclick=refresh;
form.onsubmit=async e=>{e.preventDefault();const button=document.getElementById('submit');button.disabled=true;msg.textContent='Đang tải...';try{if(editing&&!form.elements.file.files.length){const data={feature:form.elements.feature.value,version:form.elements.version.value,description:form.elements.description.value,sort_order:Number(form.elements.sort_order.value),enabled:Number(form.elements.enabled.value),game:form.elements.game.value};await asJSON('/api/admin/patches/'+editing+'/meta',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify(data)})}else{await asJSON('/api/admin/patches'+(editing?'/'+editing:''),{method:'POST',headers:{'X-CSRF-Token':csrf},body:new FormData(form)})}reset();msg.textContent='Đã lưu';await refresh()}catch(err){msg.textContent=err.message}finally{button.disabled=false}};
document.getElementById('logout').onclick=async()=>{await asJSON('/api/admin/logout',{method:'POST',headers:{'X-CSRF-Token':csrf}});location.replace('/admin')};
loadSettings().catch(e=>document.getElementById('configmsg').textContent=e.message);refresh();
</script></body></html>"""


# Inject the admin licensing panel into the existing self-contained UI.
ADMIN_HTML = ADMIN_HTML.replace("</main><script>", '\n<section class="panel" id="licensePanel"><span class="tag">04 / LICENSE KEYS</span>\n<h2>Quản lý License Key</h2><p class="muted">Tạo key theo tiền tố, thời hạn ngày/giờ tính từ lần kích hoạt đầu tiên. Chỉ Admin được tạo và thu hồi; key gốc chỉ hiển thị một lần.</p>\n<form id="licenseForm"><div class="grid">\n<div><label>Tiền tố Key (A–Z, 0–9, -)</label><input name="prefix" value="GOOHAN" maxlength="24" required></div>\n<div><label>Số ngày</label><input type="number" name="days" value="7" min="0" max="3650" required></div>\n<div><label>Số giờ (0–23)</label><input type="number" name="hours" value="0" min="0" max="23" required></div>\n<div><label>Số lượng Key (1–100)</label><input type="number" name="quantity" value="1" min="1" max="100" required></div>\n<div><label>Số thiết bị / Key</label><input type="number" name="max_devices" value="1" min="1" max="10" required></div>\n<div><label>Ghi chú</label><input name="note" maxlength="100" placeholder="Đợt phát hành / khách hàng"></div>\n</div><p class="row"><span class="small">Không lưu key gốc vào cơ sở dữ liệu.</span><button type="submit">Tạo Key mới</button></p></form>\n<div id="licenseResult" class="small" style="white-space:pre-wrap;overflow-wrap:anywhere"></div>\n<p class="row"><h3>Key đã tạo</h3><button type="button" class="secondary" id="refreshLicenses">Làm mới</button></p>\n<div id="licenseList"></div></section>\n'+"</main><script>")
ADMIN_HTML = ADMIN_HTML.replace("</script></body></html>", "\nasync function loadLicenses(){const root=document.getElementById('licenseList');try{\nconst j=await asJSON('/api/admin/licenses',{headers:{'X-CSRF-Token':csrf}});root.replaceChildren();\nfor(const k of j.licenses){const card=elem('div','','card');const bar=elem('div','','row');\nconst left=elem('div');left.append(elem('strong',k.masked),elem('div',((k.duration_seconds/3600).toFixed(1))+' giờ · '+k.devices+'/'+k.max_devices+' máy · '+(k.revoked?'Đã thu hồi':(k.expires_at&&k.expires_at*1000<Date.now()?'Hết hạn':'Đang sử dụng / chưa kích hoạt')),'muted'));\nif(k.note)left.append(elem('div',k.note,'muted'));\nconst ops=elem('div');const rev=elem('button','Thu hồi','danger');rev.disabled=k.revoked;\nrev.onclick=async()=>{if(!confirm('Thu hồi key này ngay?'))return;await asJSON('/api/admin/licenses/'+k.id+'/revoke',{method:'POST',headers:{'X-CSRF-Token':csrf}});await loadLicenses()};\nconst reset=elem('button','Đặt lại máy','secondary');reset.disabled=k.revoked;\nreset.onclick=async()=>{if(!confirm('Hủy mọi phiên đăng nhập và xóa thiết bị đã gắn?'))return;await asJSON('/api/admin/licenses/'+k.id+'/reset-devices',{method:'POST',headers:{'X-CSRF-Token':csrf}});await loadLicenses()};\nops.append(rev,document.createTextNode(' '),reset);bar.append(left,ops);card.append(bar);root.append(card)}\nif(!j.licenses.length)root.textContent='Chưa tạo key nào.';\n}catch(e){root.textContent=e.message}}\ndocument.getElementById('refreshLicenses').onclick=loadLicenses;\ndocument.getElementById('licenseForm').onsubmit=async e=>{e.preventDefault();const el=document.getElementById('licenseResult');\ntry{const f=Object.fromEntries(new FormData(e.target));for(const n of ['days','hours','quantity','max_devices'])f[n]=Number(f[n]);\nconst j=await asJSON('/api/admin/licenses',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify(f)});\nel.replaceChildren();const label=elem('p','Key vừa tạo (chỉ hiển thị lần này):');const pre=elem('pre',j.keys.join('\\n'));pre.style.whiteSpace='pre-wrap';pre.style.userSelect='all';\nconst copy=elem('button','Sao chép Key','secondary');copy.type='button';copy.onclick=()=>navigator.clipboard.writeText(j.keys.join('\\n'));\nel.append(label,pre,copy);await loadLicenses();\n}catch(err){el.textContent=err.message}};\nloadLicenses();\n"+"</script></body></html>")


def main():
    if len(ADMIN_PASSWORD) < 12:
        raise SystemExit("Thiết lập ADMIN_PASSWORD ít nhất 12 ký tự trước khi chạy.")
    if LICENSE_API_TOKEN and len(LICENSE_API_TOKEN) < 32:
        raise SystemExit("LICENSE_API_TOKEN cần tối thiểu 32 ký tự hoặc để trống.")
    init_db()
    server = ThreadingHTTPServer((HOST, PORT), RequestHandler)
    print(f"GooHan Patch Admin listening on {HOST}:{PORT}; storage={DATA}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
