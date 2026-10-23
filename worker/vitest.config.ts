import {cloudflareTest,readD1Migrations} from '@cloudflare/vitest-plugin';
import {defineConfig} from 'vitest/config';
export default defineConfig(async()=>({plugins:[cloudflareTest({wrangler:{configPath:'./wrangler.toml'},miniflare:{bindings:{TEST_MIGRATIONS:await readD1Migrations('./migrations'),PAIRING_PEPPER:'test-only-pepper-0123456789abcdef0123456789',TOKEN_ENCRYPTION_KEY:'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='}}})]}));
