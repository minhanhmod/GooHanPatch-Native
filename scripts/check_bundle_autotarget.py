#!/usr/bin/env python3
"""Verify release header is present on all 3 licensed IPA requests."""
from pathlib import Path
source = Path('ThreeOneOSFive/helpers/LicenseManager.swift')
view = Path('ThreeOneOSFive/ContentView.swift')
assert source.is_file(), 'Run this script from repository root'
s = source.read_text(encoding='utf-8')
v = view.read_text(encoding='utf-8')
assert 'GOOHAN_OFFICIAL_5_12_4' in s, 'Missing accepted release marker'
assert 'forHTTPHeaderField: "X-GooHan-Release"' in s, 'Missing release header'
assert s.count('Self.identify(&') == 3, 'Expected all 3 request types to carry release identity'
assert 'BUNDLE_AUTO_TARGET_v5.12.2' not in v, 'Old build marker displayed in app'
assert 'GOOHAN_OFFICIAL_5_12_4' not in v, 'Internal release identifier should not be displayed'
print('PASS: Official release marker present')
print('PASS: License activate, status and patch download have release identification')
print('PASS: No release marker displayed in the GooHan main UI')
print('SOURCE READY — this check does not compile or sign the IPA')
