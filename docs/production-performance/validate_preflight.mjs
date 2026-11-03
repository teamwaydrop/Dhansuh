// Offline only. No credentials, network clients or production connection.
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const root = new URL('../../', import.meta.url);
const require = createRequire(new URL('tools/waydrop-verification/package.json', root));
const { PGlite } = require('@electric-sql/pglite');
const read = name => fs.readFile(new URL(name, import.meta.url), 'utf8');
const manifest = JSON.parse(await read('ARTIFACT_MANIFEST.json'));
const results = [];
const db = new PGlite();
try {
  await db.exec(`CREATE TABLE riders(id uuid PRIMARY KEY,kyc_id uuid UNIQUE,user_id uuid UNIQUE);
    CREATE INDEX idx_riders_user_id ON riders(user_id);
    CREATE INDEX idx_riders_kyc_id ON riders(kyc_id);`);
  for (const [n, key] of [[3, 'user_id'], [4, 'kyc_id']]) {
    const drop = await read(`waves/0${n}_drop_idx_riders_${key}.sql`);
    const restore = await read(`waves/0${n}_restore_idx_riders_${key}.rollback.sql`);
    await db.exec(drop);
    assert.ok((await db.query(`SELECT to_regclass('idx_riders_${key}') AS r`)).rows[0].r);
    // Replace terminal ROLLBACK only in this isolated in-memory database.
    await db.exec(drop.replace(/ROLLBACK;\s*$/, 'COMMIT;'));
    assert.equal((await db.query(`SELECT to_regclass('idx_riders_${key}') AS r`)).rows[0].r, null);
    assert.ok((await db.query(`SELECT indisunique AND indisvalid AS ok FROM pg_index WHERE indexrelid='riders_${key}_key'::regclass`)).rows[0].ok);
    await db.exec(restore.replace(/ROLLBACK;\s*$/, 'COMMIT;'));
    assert.ok((await db.query(`SELECT to_regclass('idx_riders_${key}') AS r`)).rows[0].r);
    results.push({ check: `Split ${key} index guard, dry run, synthetic drop and exact DDL recreation`, passed: true });
  }
  // Negative drift test: a partial replacement must never authorize the drop.
  await db.exec('ALTER INDEX riders_user_id_key RENAME TO moved_unique; CREATE UNIQUE INDEX riders_user_id_key ON riders(user_id) WHERE user_id IS NOT NULL;');
  await assert.rejects(db.exec(await read('waves/03_drop_idx_riders_user_id.sql')), /Index DDL drift/);
  await db.exec('ROLLBACK;');
  results.push({ check: 'Index drift is rejected; target index survives', passed: !!(await db.query("SELECT to_regclass('idx_riders_user_id') AS r")).rows[0].r });
  for (const item of manifest.files.filter(f => f.file.endsWith('.sql'))) {
    assert.match(await read(item.file), /ROLLBACK;\s*$/);
  }
  results.push({ check: 'All eight SQL deployment/recovery drafts default to ROLLBACK', passed: true });
  const report = {
    status: 'LOCAL_CHECKS_PASS_DEPLOYMENT_HOLD',
    engine: (await db.query('SELECT version()')).rows[0].version,
    productionConnected: false,
    scope: 'Synthetic index DDL checks only. Not PG17 lock/concurrency or Supabase integration verification.',
    results,
  };
  await fs.writeFile(new URL('PREFLIGHT_LOCAL_TESTS.json', import.meta.url), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
} finally {
  await db.close();
}
