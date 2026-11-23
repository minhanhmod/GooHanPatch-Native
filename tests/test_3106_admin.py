#!/usr/bin/env python3
"""Regression tests for the Admin 3105/3106 package decoder (no network or database)."""
import hashlib
import os
import plistlib
import sys
import unittest
import uuid
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server.main import PATCH_MAGIC, convert_patch_package


def make_fixture(schema: int, private: bool = False, corrupt_digest: bool = False):
    package_id = str(uuid.uuid4()).upper()
    rule_id = str(uuid.uuid4()).upper()
    key = os.urandom(32)
    replacement = b"synthetic-fixture-only"
    digest = hashlib.sha256(replacement).digest()
    if corrupt_digest:
        digest = bytes(32)
    project = {
        "id": package_id,
        "name": "Schema test fixture",
        "bundleIdentifiers": ["com.dts.freefiremax"],
        "directories": [{"id": str(uuid.uuid4()).upper(),
                         "bundleID": "com.dts.freefiremax",
                         "relativePath": "Documents/contentcache"}],
        "rules": [{"id": rule_id,
                   "bundleID": "com.dts.freefiremax",
                   "relativePath": "Documents/contentcache/fixture.bin",
                   "replacementFilename": "fixture.bin",
                   "replacementData": replacement}],
    }
    if schema == 3:
        project["author"] = "GooHan tests"
        project["isPrivate"] = private
    payload = plistlib.dumps({"project": project, "replacementDigests": {rule_id: digest}},
                             fmt=plistlib.FMT_BINARY)
    # AESGCM returns ciphertext+tag; the stored combined data is nonce+ciphertext+tag.
    nonce = os.urandom(12)
    encrypted = nonce + AESGCM(key).encrypt(
        nonce, payload, f"3105PATCH/v{schema}/payload/{package_id}".encode()
    )
    env = {
        "schemaVersion": schema,
        "packageID": package_id,
        "isPasswordProtected": False,
        "publicContentKey": key,
        "keyFingerprint": hashlib.sha256(key).digest(),
        "encryptedPayload": encrypted,
    }
    return PATCH_MAGIC + plistlib.dumps(env, fmt=plistlib.FMT_BINARY)


class PackageSchemaTests(unittest.TestCase):
    def test_3105_schema2_stays_legacy(self):
        payload, label, package_format = convert_patch_package(
            make_fixture(2), "", "free_fire_max"
        )
        self.assertEqual(package_format, "3105")
        self.assertIn(".3105", label)
        self.assertIn(b"3105-project-v1", payload)

    def test_3106_schema3_is_published_separately(self):
        payload, label, package_format = convert_patch_package(
            make_fixture(3), "", "free_fire_max"
        )
        self.assertEqual(package_format, "3106")
        self.assertIn(".3106", label)
        self.assertIn(b"fixture.bin", payload)

    def test_private_3106_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "riêng tư"):
            convert_patch_package(make_fixture(3, private=True), "", "free_fire_max")

    def test_wrong_game_is_rejected(self):
        with self.assertRaises(ValueError):
            convert_patch_package(make_fixture(3), "", "free_fire")

    def test_corrupted_replacement_is_rejected(self):
        with self.assertRaises(ValueError):
            convert_patch_package(make_fixture(3, corrupt_digest=True), "", "free_fire_max")

    def test_unknown_schema_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Schema"):
            convert_patch_package(make_fixture(4), "", "free_fire_max")


if __name__ == "__main__":
    unittest.main()
