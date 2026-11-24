#!/usr/bin/env python3
"""Overlay GooHan Admin onto a PINNED, COMPLETE 3106 source checkout.

Only these changes are made to upstream:
- add GooHan's original server-side LicenseManager
- add the GooHan authenticated patch library view
- show original GooHan License activation UI and Admin patch library
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
# Reuse GooHan's existing application icon (only visual asset replacement).
icon_source = goohan / "ThreeOneOSFive/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
icon_target = app_root / "Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
if not icon_source.is_file() or not icon_target.is_file():
    raise FileNotFoundError("GooHan / 3106 AppIcon image missing")
shutil.copy2(icon_source, icon_target)
shutil.copy2(
    goohan / "bridge/GooHan3106Remote.swift",
    app_root / "GooHan3106Remote.swift",
)
shutil.copy2(
    goohan / "ThreeOneOSFive/helpers/LicenseManager.swift",
    app_root / "GooHanLicenseManager.swift",
)
# Restore the original GooHan license activation screen from the stable app.
# Only redirect its palette and Restore card to the full 3106 backend.
activation_source = (goohan / "ThreeOneOSFive/helpers/LicenseActivationView.swift").read_text(encoding="utf-8")
assert activation_source.count("GooPalette.all") == 2
assert activation_source.count("GooHanRecoveryPanel()") == 1
activation_source = activation_source.replace("GooPalette.all", "GH6Palette.all")
activation_source = activation_source.replace("GooHanRecoveryPanel()", "GooHan3106RestorePanel()")
(app_root / "GooHanActivationView.swift").write_text(activation_source, encoding="utf-8")

def replace_once(text: str, old: str, new: str) -> str:
    n = text.count(old)
    if n != 1:
        raise RuntimeError(f"Expected one injection anchor, found {n}: {old[:60]}")
    return text.replace(old, new, 1)

# GooHan becomes the app root (not a dismissible overlay). The complete
# upstream 3106 services still initialize from App.swift and run unmodified.
# The original 3106 home is deliberately not a License bypass route.
app_file = app_root / "App.swift"
native_app = app_file.read_text(encoding="utf-8")
native_app = replace_once(
    native_app,
    "                ContentView()",
    "                GooHan3106RemoteView()",
)
native_app = replace_once(
    native_app,
    "@State private var showOnboarding = OnboardingStore.shouldShow()",
    "@State private var showOnboarding = false",
)
# Updates now follow GooHan's controlled release process, not the upstream
# app's public update prompt. Native support selection still runs on launch.
native_app = native_app.replace("                    checkForUpdate()\n", "")
native_app = native_app.replace("                    checkForUpdateThrottled()\n", "")
native_app = native_app.replace("                checkForUpdate()\n", "")
native_app = native_app.replace("                checkForUpdateThrottled()\n", "")
app_file.write_text(native_app, encoding="utf-8")

project = upstream / "ThreeOneOSSix.xcodeproj/project.pbxproj"
pbx = project.read_text(encoding="utf-8")
build1 = "ABCD1234ABCD1234ABCD0101"
ref1 = "ABCD1234ABCD1234ABCD0102"
build2 = "ABCD1234ABCD1234ABCD0103"
ref2 = "ABCD1234ABCD1234ABCD0104"
build3 = "ABCD1234ABCD1234ABCD0105"
ref3 = "ABCD1234ABCD1234ABCD0106"
for item in (build1, ref1, build2, ref2, build3, ref3):
    if item in pbx:
        raise RuntimeError("Unexpected duplicate PBX ID")

pbx = replace_once(
    pbx,
    "/* Begin PBXBuildFile section */\n",
    "/* Begin PBXBuildFile section */\n"
    f"\t\t{build1} /* GooHan3106Remote.swift in Sources */ = "
    f"{{isa = PBXBuildFile; fileRef = {ref1}; }};\n"
    f"\t\t{build2} /* GooHanLicenseManager.swift in Sources */ = "
    f"{{isa = PBXBuildFile; fileRef = {ref2}; }};\n"
    f"\t\t{build3} /* GooHanActivationView.swift in Sources */ = "
    f"{{isa = PBXBuildFile; fileRef = {ref3}; }};\n",
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
    'path = GooHanLicenseManager.swift; sourceTree = "<group>"; };\n'
    f'\t\t{ref3} /* GooHanActivationView.swift */ = '
    '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
    'path = GooHanActivationView.swift; sourceTree = "<group>"; };\n',
)
pbx = replace_once(
    pbx,
    "\t\t\t\t3105A021 /* ContentView.swift */,\n",
    "\t\t\t\t3105A021 /* ContentView.swift */,\n"
    f"\t\t\t\t{ref1} /* GooHan3106Remote.swift */,\n"
    f"\t\t\t\t{ref2} /* GooHanLicenseManager.swift */,\n"
    f"\t\t\t\t{ref3} /* GooHanActivationView.swift */,\n",
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
    f"\t\t\t\t{build2} /* GooHanLicenseManager.swift in Sources */,\n"
    f"\t\t\t\t{build3} /* GooHanActivationView.swift in Sources */,\n",
)
old_name = "INFOPLIST_KEY_CFBundleDisplayName = 3106;"
if pbx.count(old_name) != 2:
    raise RuntimeError("Unexpected native Xcode display name settings")
pbx = pbx.replace(
    old_name, 'INFOPLIST_KEY_CFBundleDisplayName = "GooHan Patch";'
)
# Rename the Xcode product and bundle identifier; leave the target/scheme
# and native source files unchanged.
for old, new, count in (
    ("PRODUCT_NAME = 3106;", "PRODUCT_NAME = GoHaniOS;", 2),
    ("PRODUCT_BUNDLE_IDENTIFIER = com.qingtang.3106;", "PRODUCT_BUNDLE_IDENTIFIER = com.gohan.ios;", 2),
    ("3106.app", "GoHaniOS.app", 3),
    ("productName = 3106;", "productName = GoHaniOS;", 1),
):
    if pbx.count(old) != count:
        raise RuntimeError(f"Unexpected product metadata: {old}")
    pbx = pbx.replace(old, new)
project.write_text(pbx, encoding="utf-8")

info_path = app_root / "Info.plist"
with info_path.open("rb") as handle:
    info = plistlib.load(handle)
assert info["CFBundleIdentifier"] == "com.qingtang.3106"
info["CFBundleIdentifier"] = "com.gohan.ios"
info["CFBundleName"] = "GoHaniOS"
info["CFBundleDisplayName"] = "GooHan Patch"
assert info["CFBundleExecutable"] == "$(EXECUTABLE_NAME)"
with info_path.open("wb") as handle:
    plistlib.dump(info, handle, sort_keys=False)

# Retain the original signing capability request. A real App Group
# entitlement must still be provided by the signing profile.
assert "com.apple.security.application-groups" in (
    app_root / "ThreeOneOSSix.entitlements"
).read_text(encoding="utf-8")
print("GOOHAN_3106_FULL_NATIVE_OVERLAY_READY")
