#!/usr/bin/env python3
"""Ensure signed-App-Group iOS27 diagnostic remains read-only and present in UI."""
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
assert 'Label("Chẩn đoán App Groups và backend iOS 27"' in source
print("GOOHAN_SIGNED_APP_GROUP_PREFLIGHT_STATIC_PASS")
