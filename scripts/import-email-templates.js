// Run with mongosh connected explicitly to the intended database.
// TEMPLATE_FILE: absolute path to the reviewed JSON export.
// EXPECTED_DATABASE: must match the selected database (prevents accidental imports).
const fs = require('fs');
const path = require('path');
const expected = process.env.EXPECTED_DATABASE;
if (!expected || db.getName() !== expected || ['admin', 'local', 'config'].includes(expected)) {
  throw new Error('Set EXPECTED_DATABASE to the selected application database.');
}
if (!process.env.TEMPLATE_FILE) throw new Error('Set TEMPLATE_FILE to the reviewed JSON export.');
const rows = JSON.parse(fs.readFileSync(process.env.TEMPLATE_FILE, 'utf8'));
if (!Array.isArray(rows) || !rows.length || new Set(rows.map(r => r._id)).size !== rows.length ||
    rows.some(r => typeof r._id !== 'string' || typeof r.subject !== 'string' || typeof r.html !== 'string')) {
  throw new Error('Invalid or duplicate template records.');
}
const collection = db.getCollection('email_templates');
const backupPath = process.env.TEMPLATE_BACKUP || path.resolve('email-templates-before-import-' + Date.now() + '.json');
fs.writeFileSync(backupPath, EJSON.stringify(collection.find({}).toArray(), null, 2), {flag: 'wx', mode: 0o600});
const result = collection.bulkWrite(rows.map(row => ({replaceOne: {filter: {_id: row._id}, replacement: row, upsert: true}})));
print(JSON.stringify({database: db.getName(), imported: rows.length, matched: result.matchedCount, inserted: result.upsertedCount, backup: backupPath}));
