#!/usr/bin/env python3
"""Ensure the signed-App-Group diagnostic remains read-only and the Low catalog stays fixed."""
from pathlib import Path

source = Path("ThreeOneOSFive/ContentView.swift").read_text(encoding="utf-8")
start = source.index("private enum GooHanSigningPreflight {")
end = source.index("\nstruct ContentView: View {", start)
body = source[start:end]
for item in (
    "SecTaskCreateFromSelf",
    "SecTaskCopyValueForEntitlement",
    "com.apple.security.application-groups",
    "containerURL(forSecurityApplicationGroupIdentifier:",
    "HybridBackendAdvisor.integratedBackend(",
    "HybridBackendAdvisor.worseQueryImplemented",
    "static func report()",
):
    assert item in body, f"Missing signed-App-Group diagnostic: {item}"
for banned in (
    "DevicePatchService.apply(",
    "PatchTransaction.apply(",
    "ContainerStore.resolveAppContainerPath(",
    "worse_query_grant(",
):
    assert banned not in body, f"Diagnostic must remain read-only: {banned}"
# The Low edition has a fixed 3105 catalog; no 3106 UI picker remains.
# Keep all read-only diagnostic checks above, and verify the new UI contract.
assert 'private var selectedPackageFormat: String { "3105" }' in source
assert 'Text("Đang chọn Low")' in source
assert '$packagePreference' not in source
print("GOOHAN_SIGNED_APP_GROUP_PREFLIGHT_STATIC_PASS")
