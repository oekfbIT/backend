// Run only inside the local OEKFB Mongo container:
// docker exec -i oekfb-local-mongo mongosh --quiet < tools/seed-fees-local.js
// Uses the container's environment without displaying credentials. Existing settings are preserved.
const username = process.env.MONGO_INITDB_ROOT_USERNAME;
const password = process.env.MONGO_INITDB_ROOT_PASSWORD;
if (!username || !password) throw new Error('Local Mongo container credentials are missing.');
const connection = new Mongo('mongodb://' + encodeURIComponent(username) + ':' + encodeURIComponent(password) + '@127.0.0.1:27017/admin');
const localDB = connection.getDB('oekfb_database');
const result = localDB.fee_settings.updateOne({ _id: 'global' }, { $setOnInsert: {
  scope: 'global', currency: 'EUR', version: NumberInt(1),
  amounts: {
    playerRegistration: NumberInt(500), matchPostponement: NumberInt(5000),
    matchCancellationFirst: NumberInt(17000), matchCancellationSecond: NumberInt(27000),
    matchCancellationThird: NumberInt(37000), overdraft: NumberInt(5000),
    registrationDeposit: NumberInt(30000), registrationPerGame: NumberInt(8000)
  },
  updatedAt: new Date(), updatedBy: 'system', history: []
}}, { upsert: true });
printjson({ database: localDB.getName(), collection: 'fee_settings', inserted: result.upsertedId != null,
  settings: localDB.fee_settings.findOne({ _id: 'global' }) });
