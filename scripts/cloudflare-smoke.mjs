#!/usr/bin/env node
// Verifies a deployed backend using two temporary devices. Never registers a push
// token or sends a push. A marked test event is blocked without a token and then
// deleted. Writes fallback cleanup SQL containing only generated device UUIDs.
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
    `DELETE FROM connection_notices WHERE parent_id IN (${ids}) OR listener_id IN (${ids});`,
    `DELETE FROM connection_states WHERE listener_id IN (${ids});`,
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
    return {status: response.status, body, requestId: response.headers.get('x-request-id'), diagnostics: response.headers.get('x-diagnostics-status')};
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
    const beat = {
        listenerId: listener.deviceId, timestamp: new Date().toISOString(), monitoring: true,
        powerConnected: false, state: 'quiet', episodes: [], appliedConfiguration: config
    };
    const heartbeat = await request('listener/heartbeat', listener, beat);
    check(heartbeat.status === 200 && heartbeat.body.alertDuration === 5, 'listener receives five-second configuration');
    const status = await request('listener/status', parent, null, 'GET');
    check(status.status === 200 && status.body.paired && status.body.listenerId === listener.deviceId && status.body.monitoring === true, 'parent status and listener identity');
    check(status.body.configuration?.alertDuration === 5, 'parent sees the same five-second configuration');
    check(status.body.listenerConfiguration?.alertDuration === 5, 'Listener applied-settings acknowledgement');
    check(/^[0-9a-f-]{36}$/i.test(status.requestId ?? '') && status.diagnostics === 'recorded', 'live diagnostic request reference recorded');
    check(status.body.connectionAlertsEnabled === false, 'connection alerts default off');
    check((await request('connection-alerts', listener, {enabled: true})).status === 403, 'connection preferences restricted to Parent');
    check((await request('connection-alerts', parent, {enabled: true})).status === 200, 'connection alert opt-in');
    check((await request('listener/status', parent, null, 'GET')).body.connectionAlertsEnabled === true, 'connection alert preference persisted');
    check((await request('connection-alerts', parent, {enabled: false})).status === 200, 'connection alert opt-out');
    const test = await request('test-push', parent);
    check(test.status === 200 && test.body.status === 'blocked', 'marked real-test route blocked safely without push tokens');
    const testStatus = await request('listener/status', parent, null, 'GET');
    check(testStatus.body.alerts?.length === 1 && testStatus.body.alerts[0].isTest === true, 'test event clearly marked in Parent status');
    check((await request('pairing/remove', parent)).status === 200, 'authenticated unpair and shared-history cleanup');
    check((await request('listener/status', listener, null, 'GET')).body.paired === false, 'counterpart observes revoked pairing');
    check((await request('listener/heartbeat', listener, beat)).status === 409, 'revoked Listener cannot update old pair');
    const replacement = await request('pairing/create', parent);
    check(replacement.status === 200 && (await request('pairing/claim', listener, {code: replacement.body.code})).status === 200, 'replacement pairing succeeds');
    const fresh = await request('listener/status', parent, null, 'GET');
    check(fresh.body.alerts?.length === 0 && fresh.body.lastHeartbeat === null, 'old alerts and heartbeat do not reappear');
    check((await request('device/delete', listener)).status === 200, 'Listener registration and shared data deleted');
    check((await request('listener/status', listener, null, 'GET')).status === 401, 'deleted device credential revoked');
    check((await request('device/delete', parent)).status === 200, 'temporary Parent registration deleted');
    console.log('All temporary devices and shared metadata deleted through the authenticated API. No push tokens were registered and no push was sent. Fallback cleanup SQL is available.');
} catch (error) {
    console.error(`Smoke check failed: ${error instanceof Error ? error.message : 'unknown failure'}. Cleanup SQL remains available.`);
    process.exitCode = 1;
}
