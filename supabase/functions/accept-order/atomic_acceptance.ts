import postgres from 'npm:postgres@3.4.5';
import { ACCEPTANCE_SQL } from './acceptance_sql.ts';

export type AcceptanceResult = { http_status: number; success: boolean; [key: string]: unknown };

// Exported factory permits independent native connections in concurrency tests.
export function createAcceptanceExecutor(databaseUrl: string, projectUrl: string) {
  const db = new URL(databaseUrl);
  const project = new URL(projectUrl);
  const local = ['127.0.0.1', 'localhost'].includes(db.hostname) &&
    ['127.0.0.1', 'localhost'].includes(project.hostname) &&
    db.port === '54329' && db.pathname === '/waydrop_perf_test';
  if (!['postgres:', 'postgresql:'].includes(db.protocol) ||
    (!local && (project.protocol !== 'https:' || !project.hostname.endsWith('.supabase.co') ||
      db.hostname !== 'db.' + project.hostname || (db.port && db.port !== '5432')))) {
    throw new Error('Unsupported direct database endpoint');
  }
  // One connection per warm isolate; no prepared statements or pipelined arrays.
  // Production TLS verification is never disabled. Missing CA/connectivity fails closed.
  const sql = postgres(databaseUrl, {
    max: 1, prepare: false, connect_timeout: 5, idle_timeout: 10, max_lifetime: 60,
    ssl: local ? false : { rejectUnauthorized: true },
    connection: { application_name: 'waydrop_accept_order_atomic' },
  });
  return {
    async accept(orderId: string, riderId: string, actorId: string): Promise<AcceptanceResult> {
      return await sql.begin('isolation level read committed', async (tx) => {
        await tx`SET LOCAL ROLE service_role`;
        await tx`SELECT set_config('request.jwt.claim.role','service_role',true),
          set_config('request.jwt.claims','{"role":"service_role"}',true),
          set_config('request.jwt.claim.sub','',true),set_config('request.jwt.claim.email','',true),
          set_config('search_path','pg_catalog,public',true),set_config('lock_timeout','3s',true),set_config('statement_timeout','10s',true),
          set_config('app.accept_order_id',${orderId},true),
          set_config('app.accept_rider_id',${riderId},true),
          set_config('app.accept_actor_id',${actorId},true),
          set_config('app.acceptance_result','',true)`;
        await tx.unsafe(ACCEPTANCE_SQL);
        const [row] = await tx<{ result: AcceptanceResult }[]>`
          SELECT current_setting('app.acceptance_result')::jsonb AS result`;
        if (!row?.result?.http_status) throw new Error('Acceptance result missing');
        return row.result;
      }); // Resolves only after successful COMMIT; rejects on any statement/commit failure.
    },
    async close() { await sql.end({ timeout: 3 }); },
  };
}

let executor: ReturnType<typeof createAcceptanceExecutor> | undefined;
export async function acceptOrderAtomically(orderId: string, riderId: string, actorId: string) {
  if (!executor) {
    const url = Deno.env.get('SUPABASE_DB_URL');
    if (!url) throw new Error('Database connection unavailable');
    executor = createAcceptanceExecutor(url, Deno.env.get('SUPABASE_URL')!);
  }
  return await executor.accept(orderId, riderId, actorId);
}

export async function closeAcceptanceExecutor() { const current = executor; executor = undefined; if (current) await current.close(); }
