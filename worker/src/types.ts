import type {TimelineEvent} from './timeline';
export interface Env {
 CF_VERSION_METADATA?: {id:string};
 DB: D1Database;
 ALERT_REMINDERS: DurableObjectNamespace;
 WATCH_TEST: DurableObjectNamespace;
 LIVE_SOUND: DurableObjectNamespace;
 APNS_KEY_ID: string;
 APNS_TEAM_ID: string;
 APNS_PRIVATE_KEY: string;
 APNS_BUNDLE_ID: string;
 APNS_ENVIRONMENT: 'development' | 'production';
 TOKEN_ENCRYPTION_KEY: string;
 PAIRING_PEPPER: string;
}
export interface Device { id: string; role: 'parent' | 'listener'; secret_hash: string; push_token: string | null; config: string }
export interface Configuration { alertDuration: number; quietResetDuration: number; repeatInterval?: number | null; absoluteThreshold: number; snoozeDuration: number }
export const defaultConfiguration: Configuration = {alertDuration:5, quietResetDuration:20, repeatInterval:5, absoluteThreshold:-35, snoozeDuration:60};
export interface Episode {id:string; startedAt:string; endedAt?:string|null; alertSentAt?:string|null; quietConfirmed?:boolean}
export interface Heartbeat {listenerId:string; timestamp:string; monitoring:boolean; microphoneActive?:boolean; batteryLevel?:number|null; powerConnected:boolean; state:'quiet'|'possibleCry'|'crying'; currentEpisode?:Episode|null; episodes:Episode[]; appliedConfiguration?:Configuration;timelineEvents?:TimelineEvent[]}
export interface Alert { eventId:string; episodeId:string; listenerId:string; type:'sustained_cry'; cryStartedAt:string; durationSeconds:number; createdAt:string; isRepeat:boolean; isTest?:boolean }
export interface StoredEvent {event_id:string; episode_id:string; listener_id:string; parent_id:string; payload:string; status:string; attempts:number; next_attempt:number; lease_until:number|null; created_at:number; acknowledged_at:string|null; resolved_at:string|null; push_target:'phone'|'watch'|null; last_error:string|null}
export class APIError extends Error { constructor(public status:number, message:string) {super(message)} }
export function requireRole(device:Device, role:Device['role']) {if (device.role !== role) throw new APIError(403,'This device role cannot use this endpoint.');}
