import {cloudflareTest,readD1Migrations} from '@cloudflare/vitest-plugin';
import {defineConfig} from 'vitest/config';
export default defineConfig(async()=>{
 const key=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']) as CryptoKeyPair;
 const pem=btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.exportKey('pkcs8',key.privateKey) as ArrayBuffer)));
 const privateKey=`-----BEGIN PRIVATE KEY-----\n${pem}\n-----END PRIVATE KEY-----`;
 return {plugins:[cloudflareTest({wrangler:{configPath:'./wrangler.toml'},miniflare:{bindings:{
  TEST_MIGRATIONS:await readD1Migrations('./migrations'),PAIRING_PEPPER:'test-only-pepper-0123456789abcdef0123456789',TOKEN_ENCRYPTION_KEY:'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  APNS_KEY_ID:'TESTKEY',APNS_TEAM_ID:'TESTTEAM',APNS_PRIVATE_KEY:privateKey,APNS_BUNDLE_ID:'com.example.BabyCryMonitor',APNS_ENVIRONMENT:'development'
 }}})]};
});
