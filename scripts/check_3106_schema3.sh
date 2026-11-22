#!/usr/bin/env bash
# Synthetic in-memory schema-3 codec test (never touches user app data).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/main.swift" <<'SWIFT'
import Foundation
import CryptoKit

let rule = PatchRule(
    bundleID: "com.example.fixture",
    relativePath: "Documents/fixture.txt",
    replacementFilename: "fixture.txt",
    replacementData: Data("fixture-data".utf8)
)
let project = PatchProject(
    name: "Schema3 Fixture",
    author: "Integration Test",
    bundleIdentifiers: ["com.example.fixture"],
    rules: [rule]
)
let legacy = try PatchPackageCodec.encodeNew(project: project, password: nil)
let legacySummary = try PatchPackageCodec.inspect(legacy.data)
precondition(legacySummary.schemaVersion == 2)

let header = Data("3105PATCH\0".utf8)
precondition(legacy.data.starts(with: header))
let raw = legacy.data.dropFirst(header.count)
var envelope = try PropertyListSerialization.propertyList(
    from: Data(raw), format: nil
) as! [String: Any]
let key = envelope["publicContentKey"] as! Data
let encrypted = envelope["encryptedPayload"] as! Data
let packageID = project.id.uuidString
let v2AAD = Data("3105PATCH/v2/payload/\(packageID)".utf8)
let plaintext = try AES.GCM.open(
    AES.GCM.SealedBox(combined: encrypted),
    using: SymmetricKey(data: key), authenticating: v2AAD
)
let v3AAD = Data("3105PATCH/v3/payload/\(packageID)".utf8)
let sealed3 = try AES.GCM.seal(
    plaintext, using: SymmetricKey(data: key), authenticating: v3AAD
)
envelope["encryptedPayload"] = sealed3.combined!
envelope["schemaVersion"] = 3
let body3 = try PropertyListSerialization.data(
    fromPropertyList: envelope, format: .binary, options: 0
)
let sample3 = header + body3
let summary3 = try PatchPackageCodec.inspect(sample3)
precondition(summary3.schemaVersion == 3)
let decoded = try PatchPackageCodec.decode(sample3, password: nil)
precondition(decoded.project.name == project.name)
precondition(decoded.project.author == project.author)
precondition(decoded.project.rules == project.rules)
precondition(decoded.project.isPrivate == false)

do {
    _ = try PatchPackageCodec.update(
        sample3, project: decoded.project, contentKey: decoded.contentKey
    )
    fatalError("Schema3 update should remain blocked")
} catch PatchPackageError.unsupportedVersion {
    print("PASS: schema 3 can be read but not rewritten")
}

envelope["schemaVersion"] = 4
let v4Body = try PropertyListSerialization.data(
    fromPropertyList: envelope, format: .binary, options: 0
)
do {
    _ = try PatchPackageCodec.inspect(header + v4Body)
    fatalError("Unsupported schema 4 was accepted")
} catch PatchPackageError.unsupportedVersion {
    print("PASS: unknown future schema rejected")
}

print("PASS: schema 2 legacy export unchanged")
print("PASS: schema 3 decrypt, authentication and payload digest")
print("GOOHAN_3106_CODEC_TEST_PASS")
SWIFT
swiftc \
    ThreeOneOSFive/helpers/PatchProjectModels.swift \
    ThreeOneOSFive/helpers/PatchPackageCodec.swift \
    "$tmp/main.swift" \
    -o "$tmp/check_schema3"
"$tmp/check_schema3"
