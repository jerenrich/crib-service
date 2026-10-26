#!/usr/bin/env python3
"""Build one signed presentation variant without editing defaults or backend state.
Install only BabyCryWatch.app from the reported products directory. A normal
build, or the 'custom' profile here, restores the interactive long look.
"""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('profile', choices=['custom', 'system', 'minimal'])
parser.add_argument('--signing-config', required=True, type=Path)
parser.add_argument('--derived-data', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
flags = {'custom': '', 'system': 'WATCH_SYSTEM_NOTIFICATIONS', 'minimal': 'WATCH_MINIMAL_NOTIFICATIONS'}
subprocess.run(['xcodebuild', '-project', str(root/'ios/BabyCryMonitor.xcodeproj'),
    '-scheme', 'BabyCryWatch', '-configuration', 'Debug', '-destination', 'generic/platform=watchOS',
    '-derivedDataPath', str(args.derived_data.resolve()), '-xcconfig', str(args.signing_config.resolve()),
    'CODE_SIGN_IDENTITY=Apple Development',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) '+flags[args.profile], 'build'], cwd=root, check=True)
print('Watch app:', args.derived_data.resolve()/'Build/Products/Debug-watchos/BabyCryWatch.app')
