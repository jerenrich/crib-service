#!/usr/bin/env node
// Verifies a deployed backend using two temporary devices. Never registers a push
// token or sends an alert. Writes cleanup SQL containing only the generated UUIDs.
import {randomBytes, randomUUID} from 'node:crypto';
import {writeFile} from 'node:fs/promises';

const [origin, cleanupPath] = process.argv.slice(2);
if (!origin || !cleanupPath) throw new Error('Usage: node scripts/cloudflare-smoke.mjs HTTPS_ORIGIN CLEANUP_SQL_PATH');
const url = new URL(origin);
if (url.protocol !== 'https:' || url.pathname !== '/' || url.search || url.hash || url.username || url.password) {
    throw new Error('Provide an HTTPS origin without credentials or a path.');
}
const parent = {deviceId: randomUUID(), role: 'parent', secret: randomBytes(32).toString('base64')};
const listener = {deviceId: randomUUID(), role: 'listener', secret: randomBytes(32).toString('base64')};
const ids = `'${parent.deviceId}','${listener.deviceId}'`;
const cleanup = [
    `DELETE FROM events WHERE parent_id IN (${ids}) OR listener_id IN (${ids});`,
    `DELETE FROM heartbeats WHERE listener_id IN (${ids});`,
    `DELETE FROM pairs WHERE parent_id IN (${ids}) OR listener_id IN (${ids});`,
    `DELETE FROM pairing_codes WHERE parent_id IN (${ids}) OR claimed_by IN (${ids});`,
    `DELETE FROM devices WHERE id IN (${ids});`
].join('\n') + '\n';
await writeFile(cleanupPath, cleanup, {mode: 0o600, flag: 'wx'});

async function request(path, device, payload, method = 'POST') {
    const headers = {'content-type': 'application/json'};
    if (device) headers.authorization = `Bearer ${device.deviceId}.${device.secret}`;
    const response = await fetch(new URL(`/v1/${path}`, url), {
        method, headers, body: method === 'GET' ? undefined : JSON.stringify(payload ?? {}),
        signal: AbortSignal.timeout(20000)
    });
    const body = await response.json();
    return {status: response.status, body};
}
function check(condition, message) {if (!condition) throw new Error(message); console.log(`PASS ${message}`);}
try {
    check((await request('listener/status', null, null, 'GET')).status === 401, 'unauthenticated access rejected');
    check((await request('device/register', null, parent)).status === 200, 'parent registration');
    check((await request('device/register', null, listener)).status === 200, 'listener registration');
    const code = await request('pairing/create', parent);
    check(code.status === 200 && /^\d{6}$/.test(code.body.code), 'pairing code created');
    check((await request('pairing/claim', listener, {code: code.body.code})).status === 200, 'secure pairing claim');
    const config = {alertDuration: 5, quietResetDuration: 20, sensitivity: 'medium', repeatInterval: null, absoluteThreshold: -35};
    check((await request('settings', parent, config)).status === 200, 'five-second shared settings accepted');
    check((await request('settings', parent, {...config, alertDuration: 4})).status === 400, 'durations below five seconds rejected');
    const heartbeat = await request('listener/heartbeat', listener, {
        listenerId: listener.deviceId, timestamp: new Date().toISOString(), monitoring: false,
        powerConnected: false, state: 'quiet', episodes: []
    });
    check(heartbeat.status === 200 && heartbeat.body.alertDuration === 5, 'listener receives five-second configuration');
    const status = await request('listener/status', parent, null, 'GET');
    check(status.status === 200 && status.body.paired && status.body.listenerId === listener.deviceId && status.body.monitoring === false, 'parent status and listener identity');
    check(status.body.configuration?.alertDuration === 5, 'parent sees the same five-second configuration');
    console.log('No push tokens or alert events were submitted. Apply the cleanup SQL to remove these temporary devices.');
} catch (error) {
    console.error(`Smoke check failed: ${error instanceof Error ? error.message : 'unknown failure'}. Cleanup SQL remains available.`);
    process.exitCode = 1;
}
