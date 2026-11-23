#!/usr/bin/env python3
"""Static safety/integration checks for the on-device sandbox transaction probe."""
from pathlib import Path

source = Path("ThreeOneOSFive/ContentView.swift").read_text(encoding="utf-8")
start = source.index("private enum GooHanSandboxTransactionProbe {")
end = source.index("\nstruct ContentView: View {", start)
block = source[start:end]

required = (
    "fm.temporaryDirectory",
    'appendingPathComponent("GooHanSandboxProbe-\\(UUID().uuidString)"',
    "PatchTransaction.apply(",
    "PatchTransaction.restore(",
    "PatchTransaction.latestReceipt(",
    "Data(contentsOf: target) == replacement",
    "Data(contentsOf: target) == original",
    "defer { try? fm.removeItem(at: root) }",
    'guard identifier == bundleID else',
)
for needle in required:
    if needle not in block:
        raise SystemExit("FAIL: sandbox transaction preflight missing " + needle)
for banned in ("ContainerStore.", "DevicePatchService.", "MCMActivate", "KernelExploit.", "/var/mobile/Containers", "com.dts.freefire"):
    if banned in block:
        raise SystemExit("FAIL: sandbox transaction preflight reaches external app path: " + banned)
if r"\\(UUID().uuidString)" in block:
    raise SystemExit("FAIL: Swift interpolation escaped in sandbox path")
ui = source[source.index("private func runSandboxTransactionProbe()"):source.index("private func inspectPackage(")]
if r"\\(result)" in ui or r"\\(error.localizedDescription)" in ui:
    raise SystemExit("FAIL: Swift interpolation escaped in probe status")
print("GOOHAN_SANDBOX_TRANSACTION_PROBE_STATIC_CHECK_PASS")
