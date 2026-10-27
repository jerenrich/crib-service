#!/usr/bin/env python3
"""Operator tools for isolated standalone Watch pushes. Never automatically retry a push.

Private registration/token files belong under ignored .local/, never in source control.
No APNs signing key is needed: the scoped backend reuses its existing JWT authority.
"""
import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


def save_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, indent=2)
        stream.write('\n')


def post(credentials, endpoint, payload=None, authenticated=True):
    headers = {'content-type': 'application/json', 'user-agent': 'CribServiceLatencyProbe/1.0'}
    if authenticated:
        headers['authorization'] = 'Bearer ' + credentials['deviceId'] + '.' + credentials['secret']
    req = urllib.request.Request(credentials['backend'] + '/v1/' + endpoint,
        data=json.dumps(payload or {}).encode(), headers=headers, method='POST')
    # No retry loop: a timeout after sending is an uncertain result.
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials', required=True, type=Path)
    commands = parser.add_subparsers(dest='command', required=True)
    register = commands.add_parser('register')
    register.add_argument('--backend', required=True)
    token = commands.add_parser('token')
    token.add_argument('--file', type=Path, required=True)
    push = commands.add_parser('push')
    push.add_argument('--condition', choices=['locked', 'unlocked-home', 'unlocked-crib-service'], required=True)
    push.add_argument('--output', type=Path, required=True)
    push.add_argument('--delay', type=int, choices=range(0, 61), default=15, metavar='0..60')
    commands.add_parser('delete')
    args = parser.parse_args()
    if args.command == 'register':
        backend = args.backend.rstrip('/')
        url = urllib.parse.urlsplit(backend)
        if url.scheme != 'https' or not url.netloc or url.path or url.query or url.fragment or url.username:
            parser.error('Use an HTTPS backend origin without credentials, path or query.')
        if args.credentials.exists():
            credentials = json.loads(args.credentials.read_text())
            if credentials['backend'] != backend:
                parser.error('Existing registration uses a different backend.')
        else:
            credentials = {'backend': backend, 'deviceId': str(uuid.uuid4()),
                'role': 'parent', 'secret': base64.b64encode(secrets.token_bytes(32)).decode()}
            # Save before registration so a lost response can be reconciled by
            # repeating the same idempotent registration, rather than orphaning it.
            save_private(args.credentials, credentials)
        post(credentials, 'device/register', {k: credentials[k] for k in ['deviceId', 'role', 'secret']}, False)
        print('Registered temporary standalone device:', credentials['deviceId'])
        print('Configure WATCH_LATENCY_PROBE_PARENT_ID with that UUID. Credentials stay in the private file.')
        return
    credentials = json.loads(args.credentials.read_text())
    if args.command == 'token':
        token = args.file.read_text().strip()
        if not 32 <= len(token) <= 512 or len(token) % 2 or any(c not in '0123456789abcdefABCDEF' for c in token):
            parser.error('Invalid token file.')
        post(credentials, 'device/push-token', {'token': token})
        print('Standalone token registered. No notification sent.')
    elif args.command == 'delete':
        post(credentials, 'device/delete')
        args.credentials.unlink()
        print('Temporary device deleted. Remove the trial flag from the Worker configuration.')
    elif args.command == 'push':
        if args.output.exists():
            parser.error('Choose a new output file for each isolated trial.')
        print(f'Sending one marked test in {args.delay} seconds. Return to the Watch face.', flush=True)
        time.sleep(args.delay)
        record = {'requestedPhoneCondition': args.condition, 'conditionVerified': False,
            'requestStartedAt': datetime.now(timezone.utc).isoformat()}
        started = time.monotonic()
        try:
            record['response'] = post(credentials, 'watch-latency-probe/push')
        except (OSError, ValueError, urllib.error.HTTPError) as error:
            record['requestOutcome'] = 'unconfirmed; do not retry automatically'
            record['errorType'] = type(error).__name__
        record['requestDurationMS'] = round((time.monotonic() - started) * 1000)
        save_private(args.output, record)
        print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
