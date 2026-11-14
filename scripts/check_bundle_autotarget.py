#!/usr/bin/env python3
from pathlib import Path
p=Path('ThreeOneOSFive/ContentView.swift')
if not p.exists():
    raise SystemExit('ERROR: chạy script ở thư mục gốc repository')
s=p.read_text(encoding='utf-8')
checks={
 'Build marker v5.12.2': 'BUNDLE_AUTO_TARGET_v5.12.2' in s,
 'Bundle field from API': 'let targetBundleId: String?' in s,
 'Bundle check on toggle': 'patch.targetBundleId' in s,
 'No obsolete category-engine error': 'Mục lớn này chưa có engine Patch tương ứng' not in s,
 'Server plan uses bundle': 'plan.bundleId' in s,
 'Apply engine retained': 'DevicePatchService.apply(project: project)' in s,
}
for label,ok in checks.items(): print(('PASS' if ok else 'FAIL')+': '+label)
if not all(checks.values()): raise SystemExit(1)
print('SOURCE READY: đúng ContentView v5.12.2. Vẫn cần build/cài IPA mới và kiểm tra trên iPhone.')
