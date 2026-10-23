import type {Env as WorkerEnv} from '../src/types';
import type {D1Migration} from '@cloudflare/vitest-plugin';
declare global {namespace Cloudflare {interface Env extends WorkerEnv {TEST_MIGRATIONS:D1Migration[]}}}
