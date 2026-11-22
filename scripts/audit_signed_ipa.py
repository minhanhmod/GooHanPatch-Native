#!/usr/bin/env python3
"""Audit a GooHan IPA *after signing* on macOS. Read-only; never modifies IPA."""
import argparse
import pathlib
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

GROUP_KEY = "com.apple.security.application-groups"


def execute(*args):
    return subprocess.run(args, capture_output=True, check=False)


def unpack_app(ipa_path, dst):
    with zipfile.ZipFile(ipa_path) as archive:
        names = archive.namelist()
        apps = sorted({name.split("/")[1] for name in names
                       if name.startswith("Payload/") and len(name.split("/")) > 2
                       and name.split("/")[1].endswith(".app")})
        if len(apps) != 1:
            raise ValueError("IPA must contain exactly one Payload/*.app")
        prefix = "Payload/" + apps[0] + "/"
        for entry in archive.infolist():
            if not entry.filename.startswith(prefix):
                continue
            parts = pathlib.PurePosixPath(entry.filename).parts
            if ".." in parts or entry.filename.startswith("/"):
                raise ValueError("Unsafe archive path")
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise ValueError("IPA has symlinks: extract with macOS ditto and audit manually")
            target = dst.joinpath(*parts)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as reader, target.open("wb") as writer:
                shutil.copyfileobj(reader, writer)
            if mode & 0o111:
                target.chmod(0o755)
        app = dst / "Payload" / apps[0]
        if not (app / "Info.plist").is_file():
            raise ValueError("IPA app has no Info.plist")
        return app


def groups(obj):
    value = obj.get(GROUP_KEY, [])
    return sorted(set(value)) if isinstance(value, list) and all(isinstance(x, str) for x in value) else []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=pathlib.Path, help="Final IPA signed with your signing tool")
    parser.add_argument("--expect-unsigned", action="store_true",
                        help="CI mode: require the Xcode-produced IPA to be unsigned")
    args = parser.parse_args()
    if not args.ipa.is_file():
        parser.error("IPA file does not exist")

    try:
        with tempfile.TemporaryDirectory(prefix="gohan-ipa-audit-") as tmp:
            app = unpack_app(args.ipa, pathlib.Path(tmp))
            with (app / "Info.plist").open("rb") as fh:
                info = plistlib.load(fh)
            print("App:", info.get("CFBundleDisplayName", info.get("CFBundleName", "(unnamed)")))
            print("Build:", info.get("CFBundleVersion", "?"))

            if sys.platform != "darwin" or not shutil.which("codesign"):
                print("NOT_VERIFIED: macOS codesign is required to inspect the actual signed entitlement.")
                print("Do not infer App Group permission from an unsigned IPA or source plist.")
                return 2

            signature = execute("codesign", "--verify", "--strict", str(app))
            if args.expect_unsigned:
                if signature.returncode != 0:
                    print("PASS: unsigned experimental IPA (as intended); signing is a separate stage.")
                    return 0
                print("FAIL: CI artifact was unexpectedly signed")
                return 1
            if signature.returncode != 0:
                print("FAIL: IPA app is unsigned or signature verification failed.")
                print(signature.stderr.decode(errors="replace").strip()[-700:])
                return 1

            result = execute("codesign", "-d", "--entitlements", ":-", str(app))
            if result.returncode != 0:
                print("FAIL: Could not read signed entitlements")
                return 1
            try:
                signed = plistlib.loads(result.stdout)
            except (ValueError, plistlib.InvalidFileException):
                print("FAIL: Signed entitlements could not be parsed")
                return 1
            signed_groups = groups(signed)
            if not signed_groups:
                print("FAIL: signed application has NO App Group entitlement.")
                print("Re-sign with a profile that authorizes an App Group; do not deploy to iOS 27.")
                return 1

            profile_file = app / "embedded.mobileprovision"
            if not profile_file.is_file():
                print("NOT_VERIFIED: App Group listed in signature, but no embedded provisioning profile.")
                return 2
            decoded = execute("security", "cms", "-D", "-i", str(profile_file))
            if decoded.returncode != 0:
                print("NOT_VERIFIED: Could not decode provisioning profile.")
                return 2
            try:
                profile = plistlib.loads(decoded.stdout)
            except (ValueError, plistlib.InvalidFileException):
                print("NOT_VERIFIED: Invalid provisioning profile.")
                return 2
            allowed = groups(profile.get("Entitlements", {}))
            common = set(signed_groups) & set(allowed)
            if not common:
                print("FAIL: Signed App Groups do not match the provisioning profile.")
                return 1
            app_id = signed.get("application-identifier", "")
            bundle_id = info.get("CFBundleIdentifier", "")
            if app_id and bundle_id and not app_id.endswith("." + bundle_id):
                print("FAIL: Signed application-identifier does not match CFBundleIdentifier")
                return 1
            print("PASS: valid signature and matching App Group authorization")
            print("App Group count:", len(common))
            print("NOTE: this does NOT validate sandbox access or write/restore on iOS 27.2.")
            return 0
    except (OSError, zipfile.BadZipFile, ValueError) as exc:
        print("FAIL:", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
