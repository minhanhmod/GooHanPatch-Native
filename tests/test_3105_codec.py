"""Tests using synthetic, permission-safe 3105PATCH files; no game files required."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import unittest
import uuid

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

spec = importlib.util.spec_from_file_location("goohan_server", Path(__file__).resolve().parents[1] / "server" / "main.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def make_sample(password=""):
    project_id = str(uuid.uuid4()).upper()
    rule_id = str(uuid.uuid4()).upper()
    replacement = b"synthetic user-authorized test payload"
    project = {"id": project_id, "name": "Sample", "bundleIdentifiers": ["com.dts.freefireth"],
               "directories": [{"id": str(uuid.uuid4()).upper(), "bundleID": "com.dts.freefireth", "relativePath": "Documents"}],
               "rules": [{"id": rule_id, "bundleID": "com.dts.freefireth",
                          "relativePath": "Documents/test.bin", "replacementFilename": "test.bin",
                          "replacementData": replacement}]}
    pl = plistlib.dumps({"project": project, "replacementDigests": {rule_id: hashlib.sha256(replacement).digest()}}, fmt=plistlib.FMT_BINARY)
    key = bytes(range(32))
    payload = AESGCM(key).encrypt(b"p" * 12, pl, f"3105PATCH/v2/payload/{project_id}".encode())
    env = {"schemaVersion": 2, "packageID": project_id, "isPasswordProtected": bool(password),
           "keyFingerprint": hashlib.sha256(key).digest(), "encryptedPayload": b"p" * 12 + payload}
    if password:
        salt = b"s" * 16
        rounds = 100000
        derived = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, rounds, 32)
        wrapped = AESGCM(derived).encrypt(b"w" * 12, key, f"3105PATCH/v2/key/{project_id}".encode())
        env.update(keyAADVersion=2, kdfSalt=salt, kdfIterations=rounds, wrappedContentKey=b"w" * 12 + wrapped)
    else:
        env["publicContentKey"] = key
    return b"3105PATCH\0" + plistlib.dumps(env, fmt=plistlib.FMT_BINARY), replacement


class TestCodec(unittest.TestCase):
    def test_unprotected(self):
        blob, expected = make_sample()
        normalized, label = module.convert_3105(blob, "", "free_fire")
        plan = json.loads(normalized)
        self.assertEqual(plan["format"], "3105-project-v1")
        self.assertEqual(base64.b64decode(plan["rules"][0]["replacement_data"]), expected)
        self.assertIn("1 tệp", label)

    def test_protected_with_password(self):
        blob, expected = make_sample("correct_password")
        with self.assertRaises(ValueError):
            module.convert_3105(blob, "", "free_fire")
        with self.assertRaises(ValueError):
            module.convert_3105(blob, "wrong", "free_fire")
        normalized, _ = module.convert_3105(blob, "correct_password", "free_fire")
        self.assertEqual(base64.b64decode(json.loads(normalized)["rules"][0]["replacement_data"]), expected)

    def test_reject_wrong_target_game(self):
        blob, _ = make_sample()
        with self.assertRaises(ValueError):
            module.convert_3105(blob, "", "free_fire_max")

    def test_reject_bad_magic(self):
        with self.assertRaises(ValueError):
            module.convert_3105(b"not_3105", "", "free_fire")


if __name__ == "__main__":
    unittest.main()
