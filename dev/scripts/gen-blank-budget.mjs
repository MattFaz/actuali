// scripts/gen-blank-budget.mjs
// Generates the bundled blank-budget template (Actuali/Actuali/Resources/blank-budget.sqlite)
// exactly the way upstream Actual creates a new budget file: copy loot-core's
// default-db.sqlite, then apply every migration in loot-core/migrations in id
// order — the .sql files verbatim, the .js ones by importing and running the
// real upstream module (mirroring loot-core src/server/migrate/migrations.ts).
// The resulting file's __migrations__ rows are therefore a complete prefix of
// upstream's migration list, which is what desktop/web validate on load
// (checkDatabaseValidity).
//
// The JS migrations mint random UUIDs (default dashboard page/widgets), so
// those ids are baked into the template and shared by every budget Actuali
// creates — the same class of fixed id as the default category UUIDs upstream
// ships inside default-db.sqlite itself.
//
// IMPORTANT: check out the latest stable release tag in ./actual before
// running (e.g. `git -C actual checkout v26.8.1`). A template generated from
// master can carry migrations no released desktop/web client ships yet, and
// checkDatabaseValidity rejects a file whose applied migrations exceed the
// client's own list — the created budget would be unopenable elsewhere.
//
// Requires Node >= 22.18 (built-in node:sqlite + default type stripping, both
// needed to run upstream's migration modules as-is).
//
// Run from the repo root, with an actualbudget/actual checkout in ./actual:
//   node dev/scripts/gen-blank-budget.mjs [path-to-actual] [output-path]
import { copyFileSync, mkdtempSync, readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { registerHooks } from 'node:module';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const actualRepo = path.resolve(process.argv[2] ?? 'actual');
const outPath = path.resolve(process.argv[3] ?? 'Actuali/Actuali/Resources/blank-budget.sqlite');
const lootCore = path.join(actualRepo, 'packages', 'loot-core');
const migrationsDir = path.join(lootCore, 'migrations');

if (!existsSync(path.join(lootCore, 'default-db.sqlite'))) {
  console.error(`No loot-core at ${lootCore} — pass the path to an actualbudget/actual checkout.`);
  process.exit(1);
}

// The JS migrations `import { v4 } from 'uuid'`, which a plain checkout (no
// yarn install) can't resolve. Route the specifier to a stub in a temp dir
// via an in-process resolution hook — never by writing into the checkout's
// node_modules. randomUUID is a v4 UUID, so the stub is behavior-identical.
const stubDir = mkdtempSync(path.join(tmpdir(), 'uuid-stub-'));
const uuidStubPath = path.join(stubDir, 'uuid.mjs');
writeFileSync(uuidStubPath,
  "import { randomUUID } from 'node:crypto';\nexport const v4 = () => randomUUID();\n");
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === 'uuid') {
      return { url: pathToFileURL(uuidStubPath).href, shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
});

// Mirror of loot-core migrations.ts getMigrationId/getMigrationList.
const migrationId = name => parseInt(name.match(/^(\d)+/)[0]);
const migrations = readdirSync(migrationsDir)
  .filter(name => /(\.sql|\.js)$/.test(name))
  .sort((a, b) => migrationId(a) - migrationId(b));

copyFileSync(path.join(lootCore, 'default-db.sqlite'), outPath);
const db = new DatabaseSync(outPath);

// Mirror of the dbInterface loot-core's applyJavaScript hands to JS migrations.
const dbInterface = {
  runQuery(sql, params = [], fetchAll = false) {
    const stmt = db.prepare(sql);
    if (fetchAll) return stmt.all(...params);
    const info = stmt.run(...params);
    return { changes: info.changes, insertId: info.lastInsertRowid };
  },
  execQuery(sql) { db.exec(sql); },
  transaction(fn) {
    db.exec('BEGIN TRANSACTION');
    try {
      fn();
      db.exec('COMMIT');
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
  },
};

// The prefs migration reads the budget's metadata.json; a fresh budget's holds
// only { id, budgetName } (prefs.getDefaultPrefs), so it moves nothing.
const budgetDir = mkdtempSync(path.join(tmpdir(), 'blank-budget-'));
const fileId = 'blank';
writeFileSync(path.join(budgetDir, 'metadata.json'),
  JSON.stringify({ id: fileId, budgetName: 'Blank' }));
const fsStub = { getBudgetDir: () => budgetDir, join: path.join, readFile };

for (const name of migrations) {
  if (name.endsWith('.js')) {
    const { default: run } = await import(pathToFileURL(path.join(migrationsDir, name)));
    await run(dbInterface, { fs: fsStub, fileId });
  } else {
    db.exec(readFileSync(path.join(migrationsDir, name), 'utf8'));
  }
  db.prepare('INSERT INTO __migrations__ (id) VALUES (?)').run(migrationId(name));
}

// Sanity: applied ids must be exactly the migration list, in order (the prefix
// property desktop's checkDatabaseValidity requires), and the file intact.
const applied = db.prepare('SELECT id FROM __migrations__ ORDER BY id ASC').all().map(r => r.id);
const expected = migrations.map(migrationId);
if (JSON.stringify(applied) !== JSON.stringify(expected)) {
  throw new Error('applied migrations do not match the migration list');
}
const integrity = db.prepare('PRAGMA integrity_check').get();
if (integrity.integrity_check !== 'ok') throw new Error('integrity check failed');
db.exec('VACUUM');
db.close();

console.log(`Applied ${applied.length} migrations (through ${applied.at(-1)}) -> ${outPath}`);
