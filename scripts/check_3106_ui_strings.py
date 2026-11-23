#!/usr/bin/env python3
"""Catch literal Swift interpolation accidentally shown in the .3106 preflight UI."""
from pathlib import Path

source = Path("ThreeOneOSFive/ContentView.swift").read_text(encoding="utf-8")
start = source.index("private func inspectPackage(")
end = source.index("private func toggle(", start)
block = source[start:end]

required = [
    r"\(project.rules.count)",
    r"\(total)",
    r"\(error.localizedDescription)",
    "SHA256.hash(data: data)",
    "project(from: plan, for: patch)",
    "Chưa ghi vào game",
]
for item in required:
    if item not in block:
        raise SystemExit(f"FAIL: missing .3106 preflight check: {item}")
    # Two backslashes result in a literal '\\(...)' in Swift, not interpolation.
    if item.startswith("\\(") and ("\\" + item) in block:
        raise SystemExit(f"FAIL: escaped Swift interpolation: {item}")
if "DevicePatchService.apply(" in block or "DevicePatchService.restore(" in block:
    raise SystemExit("FAIL: .3106 preflight must not apply or restore anything")
print("GOOHAN_3106_PREFLIGHT_UI_TEST_PASS")
