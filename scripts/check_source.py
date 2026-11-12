#!/usr/bin/env python3
"""Run historical tests with their inactive workflow fixtures, then remove copies."""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
temporary = []
try:
    for name in ('chiich-ios-device.yml', 'chiich-ios.yml'):
        target = ROOT / '.github/workflows' / name
        if target.exists():
            raise RuntimeError('Refusing to overwrite an existing workflow fixture')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / 'build-reference' / (name + '.txt'), target)
        temporary.append(target)
    subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', 'src/element-x-ios', '-p', 'test_*.py'], cwd=ROOT, check=True)
finally:
    for target in temporary:
        target.unlink()
