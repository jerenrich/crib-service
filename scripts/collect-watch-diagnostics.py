#!/usr/bin/env python3
"""Read Watch logs without launching the app, changing notifications or polling.

The previous callback segment is optional until the first rotation. Always retain
all available files: entry callbacks and later main-actor logs join by callback_id.
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True, help='Watch CoreDevice identifier')
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
manifest = {'collected_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'files': []}
for name in ['diagnostics.txt', 'watch-callbacks.log', 'watch-callbacks.previous.log']:
    destination = args.output / name
    receipt = args.output / (name + '.copy.json')
    try:
        result = subprocess.run([
            'xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
            '--source', 'Library/Application Support/' + name,
            '--destination', str(destination), '--domain-type', 'appDataContainer',
            '--domain-identifier', 'com.jordanerenrich.cribservice.watchkitapp',
            '--timeout', '25', '--json-output', str(receipt)
        ], capture_output=True, text=True, timeout=35)
        state = 'copied' if result.returncode == 0 and destination.exists() else 'unavailable'
    except subprocess.TimeoutExpired:
        state = 'timeout'
    manifest['files'].append({'name': name, 'state': state})
    print(name + ': ' + state)
(args.output / 'watch-collection.json').write_text(json.dumps(manifest, indent=2) + '\n')
# An absent previous segment is expected. Missing required logs must stay visible.
raise SystemExit(0 if all(f['state'] == 'copied' for f in manifest['files'][:2]) else 1)
