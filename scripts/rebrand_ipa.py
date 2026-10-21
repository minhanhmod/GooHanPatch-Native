#!/usr/bin/env python3
"""Rename bundled OGIOS .3105 sample resources to GOHAN after an unsigned IPA build.

The Mach-O executable, app bundle directory, Info.plist, resource bytes, URL schemes,
licenses and entitlements are intentionally untouched. Run BEFORE signing.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import tempfile
import zipfile
from pathlib import Path

SOURCE_NAME = re.compile(r"^Payload/[^/]+/OGIOS File \((\d+)\)\.3105$")
TARGET_NAME = re.compile(r"^Payload/[^/]+/GOHAN File \((\d+)\)\.3105$")
EXPECTED = set(range(1, 15))


def scan(names):
    old = {}
    new = {}
    for name in names:
        match = SOURCE_NAME.fullmatch(name)
        if match:
            old[int(match.group(1))] = name
        match = TARGET_NAME.fullmatch(name)
        if match:
            new[int(match.group(1))] = name
    return old, new


def sha256(data):
    return hashlib.sha256(data).digest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path, help="An unsigned iOS .ipa file")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--in-place", action="store_true", help="Atomically rewrite the IPA")
    group.add_argument("--output", type=Path, help="Write an independent IPA")
    group.add_argument("--check", action="store_true", help="Require all 14 GOHAN names")
    args = parser.parse_args()
    if not args.ipa.is_file():
        parser.error(f"File not found: {args.ipa}")
    if args.output and args.ipa.resolve() == args.output.resolve():
        parser.error("Use --in-place instead of --output pointing at the same file")

    with zipfile.ZipFile(args.ipa, "r") as src:
        names = src.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError("IPA contains duplicate paths; refusing to repack")
        old, new = scan(names)
        if args.check:
            if old or set(new) != EXPECTED:
                raise RuntimeError(f"EXPECTED only GOHAN 1-14; found old={sorted(old)} new={sorted(new)}")
            print(f"PASS: all {len(new)} .3105 files are named GOHAN (payload unchanged)")
            return
        if set(old) & set(new):
            raise RuntimeError("Mixed OGIOS / GOHAN file collision; refusing to overwrite")
        if (set(old) | set(new)) != EXPECTED:
            raise RuntimeError(f"Unexpected samples: OGIOS={sorted(old)} GOHAN={sorted(new)} (expected 1-14)")
        if any('/_CodeSignature/' in name or name.endswith('/embedded.mobileprovision') for name in names):
            raise RuntimeError("IPA appears signed. Rename resources BEFORE code signing")

        if old:
            rename = {name: name.replace('/OGIOS File (', '/GOHAN File (', 1) for name in old.values()}
            print(f"Renaming {len(rename)} resource files; keeping their contents unchanged")
        else:
            rename = {}
            print("All 14 files already named GOHAN; no changes needed")

        destination = args.output or args.ipa
        destination.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(prefix='.gohan-rename-', suffix='.ipa', dir=destination.parent)
        os.close(fd)
        tmp = Path(temp_name)
        try:
            with zipfile.ZipFile(tmp, 'w') as out:
                out.comment = src.comment
                for info in src.infolist():
                    raw = src.read(info.filename)
                    # Build a new ZipInfo to avoid mutating the input object's entry.
                    clone = zipfile.ZipInfo(rename.get(info.filename, info.filename), info.date_time)
                    clone.compress_type = info.compress_type
                    clone.comment = info.comment
                    clone.extra = info.extra
                    clone.create_system = info.create_system
                    clone.create_version = info.create_version
                    clone.extract_version = info.extract_version
                    clone.flag_bits = info.flag_bits
                    clone.volume = info.volume
                    clone.internal_attr = info.internal_attr
                    clone.external_attr = info.external_attr
                    out.writestr(clone, raw)
            # Verify unchanged payload content and paths other than the renamed files.
            with zipfile.ZipFile(tmp, 'r') as out:
                old_after, new_after = scan(out.namelist())
                if old_after or set(new_after) != EXPECTED:
                    raise RuntimeError("Post-build naming verification failed")
                if set(out.namelist()) != {rename.get(n, n) for n in names}:
                    raise RuntimeError("An unexpected path changed")
                for original in names:
                    expected_name = rename.get(original, original)
                    if sha256(src.read(original)) != sha256(out.read(expected_name)):
                        raise RuntimeError(f"Content changed: {original}")
            os.replace(tmp, destination)
            print(f"PASS: wrote {destination} | renamed={len(rename)} | verified original bytes of every file")
        finally:
            if tmp.exists():
                tmp.unlink()

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, zipfile.BadZipFile) as exc:
        print('ERROR:', exc, file=sys.stderr)
        sys.exit(1)
