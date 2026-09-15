# Fees and amounts

Admin: **Finanzen → Gebühren & Beträge**, `/admin/fees`.

MongoDB stores one `fee_settings` document with `_id: "global"`. All prices are integer EUR cents. `FeeSettingsMigration` seeds defaults using `$setOnInsert`; migration retries preserve existing prices. The local-only `tools/seed-fees-local.js` can seed the local container without running unrelated migrations:

```sh
docker exec -i oekfb-local-mongo mongosh --quiet < tools/seed-fees-local.js
```

## API

- `GET /admin/fees`: admin authentication required, current settings and history.
- `PATCH /admin/fees`: admin authentication required. Send `{ "version": 1, "amounts": { ...all eight known keys... } }`. All amounts must be integer cents in the range 0–100,000,000. Zero is valid. Changes and audit history are one atomic compare-and-swap; stale versions return 409.
- `GET /admin/fees/history`: newest first, admin only.
- `GET /app/fees`: prices and version only, no administrator identities/history.

Dictionary keys remain camelCase; ordinary response properties use the app's existing snake_case encoding. The fee page accepts both naming conventions for metadata.

## Charges

Player registration, cancellation tiers (1/2/3), overdraft, and registration deposit/per-game calculations read a validated settings snapshot before side effects. Missing/invalid settings reject the operation. Invoices save `appliedFee` with the positive amount in cents, currency, key and version. Player invoice sums keep the legacy negative sign, while the configured fee remains positive. Registrations save `appliedFees` plus their existing `kaution` value; emails and admin labels show that saved deposit.

Postponement approval authenticates the recipient team's owner or an admin, charges the requester, and records a durable receipt in the team document atomically with the balance debit. Request UUID is the deterministic invoice ID. Retries reuse the receipt and repair a missing invoice without debiting twice. Requests already approved before rollout do not acquire a retrospective fee. An interrupted approval can be retried to complete the invoice/request; no background recovery worker is introduced.

## Client rollout

Clients should fetch `/app/fees` when showing a priced action, show the applicable amount, and send `X-Fee-Version` with the action. A stale version returns 409 before side effects; fetch again and ask the user to confirm the revised price. The header is optional for compatibility with existing mobile/web clients. This checkout contains the admin frontend; other client repositories still need to adopt that display/version handshake. Backend charges always use database values even for older clients.

The shared per-game registration rate is a global default already used by both registration controllers. League referee rates and team/season-specific prices remain in their existing models.

## Validation

```sh
FEE_TEST_MONGO_PORT=27029 swift test --filter FeeSettingsTests
```

Use a disposable, unauthenticated MongoDB on loopback. Tests create unique databases and remove only those test databases. Coverage includes seeding, exact cents, missing settings, concurrent writes, history, endpoint permissions, public projection, stale quotes, duplicate postponement charges, and invoice recovery across price changes.
