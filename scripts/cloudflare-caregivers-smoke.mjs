#!/usr/bin/env node
// Post-deployment caregiver check. Uses only new temporary devices, never
// registers APNs tokens, and deletes every temporary device before exiting.
import {randomBytes, randomUUID} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
const [origin, cleanupFile] = process.argv.slice(2);
if (!origin || !cleanupFile) throw new Error('Usage: node scripts/cloudflare-caregivers-smoke.mjs HTTPS_ORIGIN CLEANUP_SQL_PATH');
const base = new URL(origin);
if (base.protocol !== 'https:' || base.pathname !== '/' || base.search || base.hash || base.username || base.password) throw new Error('Use an HTTPS origin.');
const device = role => ({deviceId: randomUUID(), role, secret: randomBytes(32).toString('base64')});
const parent = device('parent'), listener = device('listener'), partner = device('parent');
const ids = [parent, listener, partner].map(d => `'${d.deviceId}'`).join(',');
const tables = ['caregiver_deliveries','caregiver_invites','caregiver_families','silent_alarm_cycles','monitoring_commands','resolved_episodes','alert_snoozes','timeline_events','connection_notices','connection_states','events','heartbeats','pairs','pairing_codes','devices'];
const columns = {
 caregiver_deliveries: 'device_id', caregiver_invites: 'owner_id', caregiver_families: 'owner_id',
 connection_states: 'listener_id', heartbeats: 'listener_id', devices: 'id'
};
const cleanup = tables.map(t => `DELETE FROM ${t} WHERE ${columns[t] ?? 'parent_id'} IN (${ids});`).join('\n') + '\n';
await writeFile(cleanupFile, cleanup, {mode: 0o600, flag: 'wx'});
async function request(path, d, payload, method = 'POST') {
 const response = await fetch(new URL(`/v1/${path}`, base), {method,
  headers: {'content-type': 'application/json', ...(d ? {authorization: `Bearer ${d.deviceId}.${d.secret}`} : {})},
  body: method === 'GET' ? undefined : JSON.stringify(payload ?? {}), signal: AbortSignal.timeout(20000)});
 return {status: response.status, body: await response.json(), diagnostics: response.headers.get('x-diagnostics-status')};
}
function check(ok, label) { if (!ok) throw new Error(label); console.log(`PASS ${label}`); }
const status = d => request('listener/status', d, null, 'GET');
try {
 const denied = await status(null);
 check(denied.status === 401 && denied.diagnostics === 'recorded', 'authentication and diagnostic storage');
 for (const d of [parent, listener, partner]) check((await request('device/register', null, d)).status === 200, `temporary ${d.role} registration`);
 const nurseryCode = await request('pairing/create', parent);
 check(nurseryCode.status === 200, 'nursery pairing code');
 check((await request('pairing/claim', listener, {code: nurseryCode.body.code})).status === 200, 'nursery paired');
 const invite = await request('caregivers/invite', parent, {name: 'Deployment primary'});
 check(invite.status === 200, 'caregiver invitation');
 check((await request('caregivers/join', partner, {name: 'Deployment secondary', code: invite.body.code})).status === 200, 'caregiver joined');
 let duty = (await status(parent)).body.caregiverDuty;
 const member = (await status(partner)).body;
 check(duty?.caregivers.length === 2 && member.paired && member.listenerId === listener.deviceId, 'both caregivers share the nursery');
 async function update(value) {
  const r = await request('caregivers/duty', partner, {revision: duty.revision, ...value});
  check(r.status === 200, 'duty mutation confirmed'); duty = r.body;
 }
 const oldRevision = duty.revision;
 await update({caregiverId: partner.deviceId, secondaryEnabled: false});
 await update({primaryId: partner.deviceId});
 await update({primaryId: parent.deviceId, escalationSeconds: 180});
 check(duty.primaryId === parent.deviceId && duty.escalationSeconds === 180 && duty.caregivers.find(c => c.id === partner.deviceId).secondaryEnabled === false, 'exclusive primary and persistent secondary opt-out');
 check((await request('caregivers/duty', parent, {revision: oldRevision, primaryId: partner.deviceId})).status === 409, 'stale duty update rejected');
 const configuration = {alertDuration: 30, quietResetDuration: 20, repeatInterval: 5, absoluteThreshold: -45, snoozeDuration: 120};
 check((await request('settings', partner, configuration)).status === 200, 'partner saves shared configuration');
 check((await status(parent)).body.configuration.alertDuration === 30, 'cry duration shared with original Parent');
 const now = new Date().toISOString();
 const event = {eventId: randomUUID(), episodeId: randomUUID(), listenerId: listener.deviceId, type: 'sustained_cry', cryStartedAt: now, createdAt: now, durationSeconds: 0, isRepeat: false};
 const uploaded = await request('listener/event', listener, event);
 check(uploaded.status === 200 && ['pending','blocked'].includes(uploaded.body.status), 'cry alert accepted without any push destinations');
 check((await status(partner)).body.alerts.length === 0, 'off-duty partner has no active cry alert');
 check((await request('alert/acknowledge', partner, {eventId: event.eventId})).status === 200, 'partner snoozes shared alert');
 const a = (await status(parent)).body, b = (await status(partner)).body;
 check(a.alertsMutedUntil === b.alertsMutedUntil && Date.parse(a.alertsMutedUntil) > Date.now() && a.snoozedBy === partner.deviceId, 'shared snooze and caregiver attribution');
 check((await request('alert/resume', parent, {expectedUntil: Date.parse(a.alertsMutedUntil)})).status === 200, 'original Parent resumes shared alerts');
 check((await request('pairing/remove', partner)).status === 200, 'invited caregiver disconnects independently');
 check(!(await status(partner)).body.paired && (await status(parent)).body.paired, 'original nursery pairing survives partner disconnect');
 console.log('Caregiver deployment smoke check passed; no APNs tokens were registered.');
} finally {
 let failures = 0;
 for (const d of [partner, parent, listener]) {
  try { const result = await request('device/delete', d); if (result.status !== 200 && result.status !== 401) throw new Error('cleanup rejected'); }
  catch { failures++; }
 }
 if (failures) { console.error(`Temporary-device cleanup incomplete. Apply the generated cleanup SQL: ${cleanupFile}`); process.exitCode = 1; }
 else console.log('PASS temporary devices deleted');
}
