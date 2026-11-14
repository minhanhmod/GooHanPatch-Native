#!/usr/bin/env python3
"""Optional static audit of the official GooHan IPA UI/privacy port."""
from pathlib import Path
p = Path("ThreeOneOSFive/ContentView.swift")
if not p.is_file():
    raise SystemExit("ERROR: chạy script trong thư mục gốc repository")
s = p.read_text(encoding="utf-8")
checks = {
    "No settings build banner": 'Text("GooHan IPA • BUNDLE_AUTO_TARGET_v5.12.2")' not in s,
    "No bundle identifier underneath Patch": 'Text(target)' not in s and 'Text(patch.targetBundleId)' not in s,
    "No dev version in sync status": '"[BUNDLE_AUTO_TARGET_v5.12.2]' not in s,
    "Presentation redaction present": 'GooPublicText.withoutBundleIdentifiers(message)' in s,
    "API bundle field preserved": 'let targetBundleId: String?' in s,
    "Native app target preserved": 'let bundleID = plan.bundleId ?? fallback' in s,
    "Bundle guard preserved": 'bundleID == serverBundle' in s,
    "Patch apply engine preserved": 'DevicePatchService.apply(project: project)' in s,
    "Restore engine preserved": 'DevicePatchService.restore(receipt: receipt)' in s,
    "Legacy category error absent": 'Mục lớn này chưa có engine Patch tương ứng' not in s,
}
for label, ok in checks.items():
    print(("PASS" if ok else "FAIL") + ": " + label)
if not all(checks.values()):
    raise SystemExit(1)
print("SOURCE READY: bản UI ẩn Bundle ID, không đổi engine Patch/License.")
