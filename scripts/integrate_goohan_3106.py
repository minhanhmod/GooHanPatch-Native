#!/usr/bin/env python3
"""Overlay GooHan Admin onto a PINNED, COMPLETE 3106 source checkout.

Only these changes are made to upstream:
- add GooHan's original server-side LicenseManager
- add the GooHan authenticated patch library view
- show a GooHan entry on 3106's home tab
- register the two new Swift files with Xcode
- change the visible app name
Do not replace worse_query/SandboxAccess/DevicePatchService/transaction files.
"""
from pathlib import Path
import plistlib
import shutil
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: integrate_goohan_3106.py <upstream-root> <goohan-root>")

upstream = Path(sys.argv[1]).resolve()
goohan = Path(sys.argv[2]).resolve()
assert (upstream / "ThreeOneOSSix/exploit/worse_query.m").is_file()
assert (upstream / "ThreeOneOSSix/helpers/SandboxAccess.swift").is_file()
assert (upstream / "ThreeOneOSSix/helpers/DevicePatchService.swift").is_file()

app_root = upstream / "ThreeOneOSSix"
shutil.copy2(
    goohan / "bridge/GooHan3106Remote.swift",
    app_root / "GooHan3106Remote.swift",
)
shutil.copy2(
    goohan / "ThreeOneOSFive/helpers/LicenseManager.swift",
    app_root / "GooHanLicenseManager.swift",
)

def replace_once(text: str, old: str, new: str) -> str:
    n = text.count(old)
    if n != 1:
        raise RuntimeError(f"Expected one injection anchor, found {n}: {old[:60]}")
    return text.replace(old, new, 1)

cv = app_root / "ContentView.swift"
source = cv.read_text(encoding="utf-8")
source = replace_once(
    source,
    "    @State private var showSettings = false",
    "    @State private var showSettings = false\n    @State private var showGooHanRemote = false",
)
source = replace_once(
    source,
    "        .sheet(isPresented: $showSettings) { SettingsView() }",
    "        .sheet(isPresented: $showSettings) { SettingsView() }\n"
    "        .sheet(isPresented: $showGooHanRemote) { GooHan3106RemoteView() }",
)
source = replace_once(
    source,
    "                onOpenLogs: openLogs\n            )\n        case .new:",
    '                onOpenLogs: openLogs\n'
    '            )\n'
    '            .safeAreaInset(edge: .top) {\n'
    '                Button {\n'
    '                    showGooHanRemote = true\n'
    '                } label: {\n'
    '                    Label("GooHan Patch • Đồng bộ từ Admin", systemImage: "bolt.shield.fill")\n'
    '                        .font(.subheadline.weight(.bold))\n'
    '                        .frame(maxWidth: .infinity)\n'
    '                        .padding(.vertical, 10)\n'
    '                }\n'
    '                .buttonStyle(.borderedProminent)\n'
    '                .tint(.pink)\n'
    '                .padding(.horizontal, 18)\n'
    '            }\n'
    '        case .new:',
)
cv.write_text(source, encoding="utf-8")

project = upstream / "ThreeOneOSSix.xcodeproj/project.pbxproj"
pbx = project.read_text(encoding="utf-8")
build1 = "ABCD1234ABCD1234ABCD0101"
ref1 = "ABCD1234ABCD1234ABCD0102"
build2 = "ABCD1234ABCD1234ABCD0103"
ref2 = "ABCD1234ABCD1234ABCD0104"
for item in (build1, ref1, build2, ref2):
    if item in pbx:
        raise RuntimeError("Unexpected duplicate PBX ID")

pbx = replace_once(
    pbx,
    "/* Begin PBXBuildFile section */\n",
    "/* Begin PBXBuildFile section */\n"
    f"\t\t{build1} /* GooHan3106Remote.swift in Sources */ = "
    f"{{isa = PBXBuildFile; fileRef = {ref1}; }};\n"
    f"\t\t{build2} /* GooHanLicenseManager.swift in Sources */ = "
    f"{{isa = PBXBuildFile; fileRef = {ref2}; }};\n",
)
pbx = replace_once(
    pbx,
    "/* Begin PBXFileReference section */\n",
    "/* Begin PBXFileReference section */\n"
    f'\t\t{ref1} /* GooHan3106Remote.swift */ = '
    '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
    'path = GooHan3106Remote.swift; sourceTree = "<group>"; };\n'
    f'\t\t{ref2} /* GooHanLicenseManager.swift */ = '
    '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
    'path = GooHanLicenseManager.swift; sourceTree = "<group>"; };\n',
)
pbx = replace_once(
    pbx,
    "\t\t\t\t3105A021 /* ContentView.swift */,\n",
    "\t\t\t\t3105A021 /* ContentView.swift */,\n"
    f"\t\t\t\t{ref1} /* GooHan3106Remote.swift */,\n"
    f"\t\t\t\t{ref2} /* GooHanLicenseManager.swift */,\n",
)
pbx = replace_once(
    pbx,
    "\t\t3105A700 /* Sources */ = {\n"
    "\t\t\tisa = PBXSourcesBuildPhase;\n"
    "\t\t\tbuildActionMask = 2147483647;\n"
    "\t\t\tfiles = (\n",
    "\t\t3105A700 /* Sources */ = {\n"
    "\t\t\tisa = PBXSourcesBuildPhase;\n"
    "\t\t\tbuildActionMask = 2147483647;\n"
    "\t\t\tfiles = (\n"
    f"\t\t\t\t{build1} /* GooHan3106Remote.swift in Sources */,\n"
    f"\t\t\t\t{build2} /* GooHanLicenseManager.swift in Sources */,\n",
)
old_name = "INFOPLIST_KEY_CFBundleDisplayName = 3106;"
if pbx.count(old_name) != 2:
    raise RuntimeError("Unexpected native Xcode display name settings")
pbx = pbx.replace(
    old_name, 'INFOPLIST_KEY_CFBundleDisplayName = "GooHan Patch 3106";'
)
project.write_text(pbx, encoding="utf-8")

info_path = app_root / "Info.plist"
with info_path.open("rb") as handle:
    info = plistlib.load(handle)
assert info["CFBundleIdentifier"] == "com.qingtang.3106"
info["CFBundleDisplayName"] = "GooHan Patch 3106"
with info_path.open("wb") as handle:
    plistlib.dump(info, handle, sort_keys=False)

# Retain the original signing capability request. A real App Group
# entitlement must still be provided by the signing profile.
assert "com.apple.security.application-groups" in (
    app_root / "ThreeOneOSSix.entitlements"
).read_text(encoding="utf-8")
print("GOOHAN_3106_FULL_NATIVE_OVERLAY_READY")
