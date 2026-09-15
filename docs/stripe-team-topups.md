# Team top-ups with Stripe

Teams pay by card and the backend credits their existing `Team.balance`. Negative balances are supported: a €100 payment changes −€40 to €60. The full payment is credited; ÖKFB covers Stripe fees. Money is charged to the Stripe account owning the backend key. No withdrawals, Connect accounts, saved cards, or automatic recurring top-ups are implemented.

Two app integrations are available: **open a hosted Checkout link** (no Stripe client SDK needed), or use the existing PaymentIntent/SDK endpoint. Both create the same paid invoice and confirmation email after verified payment success.

## Environment and sandbox/production selection

Add these to the backend environment (never commit real keys):

```dotenv
STRIPE_MODE=sandbox
STRIPE_SANDBOX_SECRET_KEY=sk_test_...
STRIPE_SANDBOX_PUBLISHABLE_KEY=pk_test_...
STRIPE_SANDBOX_WEBHOOK_SECRET=whsec_...
STRIPE_PRODUCTION_SECRET_KEY=sk_live_...
STRIPE_PRODUCTION_PUBLISHABLE_KEY=pk_live_...
STRIPE_PRODUCTION_WEBHOOK_SECRET=whsec_...
# Required only for hosted Checkout; replace with pages in your app/site
STRIPE_CHECKOUT_SUCCESS_URL=https://YOUR-APP/finance/payment-return
STRIPE_CHECKOUT_CANCEL_URL=https://YOUR-APP/finance/payment-cancel
# Optional: maximum per payment in EUR cents; default €5,000
STRIPE_TOPUP_MAX_MINOR=500000
```

The local `.env` contains blank slots for these values; `.env.example` is the shareable template. Real credentials must be filled in locally or in DigitalOcean. The old unprefixed `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, and `STRIPE_WEBHOOK_SECRET` names are no longer used.

`STRIPE_MODE=sandbox` selects only `STRIPE_SANDBOX_*`; `STRIPE_MODE=production` selects only `STRIPE_PRODUCTION_*`. Missing mode defaults to sandbox. An invalid mode, missing active credentials, or mismatched key prefixes returns `503` on payment routes; it never falls back to the other environment. Unused credentials may stay blank. `GET /payments/config` exposes `stripe_mode`, `livemode`, and the selected publishable key, never secret keys.

### DigitalOcean and app builds

In DigitalOcean App Platform, open **Apps → your app → Settings → backend component → Environment Variables → Edit**. Set `STRIPE_MODE` and the credentials as **runtime environment variables** on the backend service; mark secret API keys and webhook secrets as encrypted secrets. Redeploy/restart after changes. Swift release/debug compilation does not choose the Stripe environment, and secrets should not be embedded in build arguments or the client app. [DigitalOcean environment settings](https://docs.digitalocean.com/products/app-platform/how-to/use-environment-variables/).

For simultaneous test and production app builds, deploy separate sandbox and production backends with separate databases. Set the app build's API base URL to the corresponding backend and initialize its Stripe SDK from `/payments/config`. Checkout uses that backend's selected account automatically. A client request cannot change the backend mode. If you switch a single deployment's mode, pending payments from the previous mode will not be reconciled while that mode is inactive; keep the original backend running until its pending payments finish.

### Where to find both sets of credentials

1. In Stripe's account picker, select the intended **sandbox**. Open **Developers → API keys** and copy its test secret/publishable pair into `STRIPE_SANDBOX_*`.
2. Open **Workbench → Webhooks** (or the Dashboard's Webhooks section), create/select the endpoint for `https://YOUR-SANDBOX-BACKEND/payments/stripe/webhook`, then reveal its **Signing secret**. Put its `whsec_...` value in `STRIPE_SANDBOX_WEBHOOK_SECRET`.
3. Switch to the **live account/environment** and repeat for the production API keys and production backend webhook. Put that endpoint's separate signing secret in `STRIPE_PRODUCTION_WEBHOOK_SECRET`.

You need a webhook signing secret for **each environment**. Both start with `whsec_`; they are not interchangeable, even if endpoint URLs match. For local CLI forwarding, use the secret printed by `stripe listen` as your local sandbox webhook secret; it differs from Dashboard endpoint secrets. See [Stripe API keys](https://docs.stripe.com/keys) and [webhook signing secrets](https://docs.stripe.com/webhooks/signature).

**What to create:** register the webhook below in Stripe and provide these two return pages in your app/site. The backend creates each Checkout Session with a fixed amount and team reference, so there is no need to create Dashboard Payment Links, Products, or Prices yourself. HTTPS return URLs are required; sandbox also accepts HTTP on `localhost`/`127.0.0.1`. The backend appends `top_up_id` to both return URLs. Missing return URLs disable Checkout creation only; SDK payments and background recovery still work.

Email uses the existing configuration:

```dotenv
SMTP_HOST=smtp.easyname.com
SMTP_PORT=587
SMTP_USERNAME=...
SMTP_PASSWORD=...
SMTP_FROM_ADDRESS=office@oekfb.eu
SMTP_FROM_NAME=ÖKFB
```

The application applies its migrations and starts its scheduled jobs in `configure.swift`. `TeamTopUpRecoveryJob` runs every minute at second 15. Keep the backend running: the persisted payment/email work survives restarts and supports standalone MongoDB. No extra worker command or database replica set is needed.

**Use a separate development database for sandbox payments.** Sandbox credits change real `Team.balance` values in whichever database the backend is configured to use. Sandbox confirmation emails use the configured SMTP service and are marked as test payments.

## Stripe webhook

In the sandbox Dashboard, register:

```text
POST https://YOUR-BACKEND/payments/stripe/webhook
```

Select these events (add the Checkout events to your existing endpoint):

```text
payment_intent.succeeded
payment_intent.payment_failed
payment_intent.canceled
checkout.session.completed
checkout.session.async_payment_succeeded
checkout.session.async_payment_failed
checkout.session.expired
```

Copy the endpoint's signing secret into `STRIPE_SANDBOX_WEBHOOK_SECRET` or `STRIPE_PRODUCTION_WEBHOOK_SECRET`, matching the endpoint's environment. The backend pins outgoing Stripe API requests to `2024-06-20`; use that event version where available. The webhook consumes stable event identifiers/metadata and retrieves the current Stripe objects before crediting. Checkout currently offers card payments; delayed completion events are also handled.

For local development:

```sh
stripe listen \
  --events payment_intent.succeeded,payment_intent.payment_failed,payment_intent.canceled,checkout.session.completed,checkout.session.async_payment_succeeded,checkout.session.async_payment_failed,checkout.session.expired \
  --forward-to localhost:8080/payments/stripe/webhook
```

Use the `whsec_...` printed by this CLI session while forwarding locally. The webhook authenticates with `Stripe-Signature`, not a user token.

## App endpoints

All endpoints below require `Authorization: Bearer YOUR_EXISTING_LOGIN_TOKEN`. Team users can access only their own teams; administrators can access any team. JSON uses the backend's existing **snake_case** convention.

| Method and path | Purpose |
| --- | --- |
| `GET /payments/config` | Publishable key, EUR limits, `stripe_mode`, sandbox/live flag, `checkout_enabled` |
| `POST /payments/teams/:teamID/top-ups/checkout` | Create or resume a hosted payment link |
| `POST /payments/teams/:teamID/top-ups` | Create or resume an SDK payment |
| `GET /payments/top-ups/:topUpID` | Read payment/credit/email status |
| `GET /payments/top-ups/:topUpID/confirmation` | Check completion using HTTP status codes below |
| `GET /payments/teams/:teamID/invoices?page=1&per=20` | Existing invoice history, newest first |

History accepts `source=stripe` or `source=manual` (manual also includes older records without a source). It returns the normal Fluent page: `items` and `metadata`.

### Option A: cashier button opens a payment link

1. Generate a UUID for this payment attempt and keep it until the attempt finishes.
2. Call `POST /payments/teams/TEAM_UUID/top-ups/checkout` with:

```json
{ "amount_minor": 10000, "idempotency_key": "ce29cbae-2cf3-4ec9-a135-e874de51ddae" }
```

3. Save the response `id` (the top-up ID) and open `checkout_url` in the browser. The response also includes `payment_flow: "checkout"`, `checkout_session_id`, `checkout_expires_at`, and `status: "open"`. It does not expose a PaymentIntent client secret. A concurrent request may briefly return `creating` without a URL; repeat the same POST after a short wait.
4. Stripe hosts card entry and bank authentication. On return to your app—or while the finance screen is open—poll `GET /payments/top-ups/TOP_UP_ID/confirmation` about every 3 seconds, backing off after a short wait. Your return page receives `top_up_id`; authenticate the user normally before querying it. This also works when another person pays the link for the team.
5. When the endpoint returns `200` with `status: "credited"`, show success and refresh the balance/invoices. The background worker still finishes payments and sends emails when the user closes the browser.

| Confirmation HTTP status | Meaning / app action |
| --- | --- |
| `200` | Payment verified, balance credited, invoice recorded. Email may still be sending. |
| `202` | Pending (including payment processing or accounting recovery). Keep waiting; `Retry-After: 3`. |
| `402` | Stripe reports a failed payment attempt. A declined card can be retried using the same open Checkout link. |
| `410` | Session expired or payment canceled. A deliberate new payment needs a new key. |
| `409` | Needs administrator review; do not automatically create another payment. |

All these responses contain the normal top-up JSON. Authentication/not-found errors use the normal API error format. The ordinary `GET /payments/top-ups/:id` still returns `200` when a record is readable; inspect its `status` for the payment outcome.

**Creating a link (`200`), acknowledging a webhook (`200`), or reaching the success URL does not confirm a deposit.** Only the confirmation endpoint's `200`/`credited` means the deposit has been applied. Stripe must report a successful PaymentIntent for the expected team, currency, and full amount. `checkout.session.completed` alone can still be unpaid. This confirms successful payment to the Stripe account; it does not wait for Stripe's later payout to your bank.

Returning via the cancel page or closing the browser does not cancel the Stripe payment. Query its status; an open session can be resumed until Stripe expires it (normally 24 hours). After network errors, retry with the **same key, amount, and endpoint**. Reusing a key across SDK and Checkout flows returns `409`. Both return URLs are saved with the attempt so recovery sends the original parameters even if environment settings change.

### Option B: cashier button uses the Stripe SDK

1. Fetch `/payments/config` and initialize Stripe's client SDK with `publishable_key`.
2. Generate a UUID for this payment attempt and keep it until the attempt finishes.
3. Start the payment:

```http
POST /payments/teams/TEAM_UUID/top-ups
Authorization: Bearer YOUR_LOGIN_TOKEN
Content-Type: application/json

{
  "amount_minor": 10000,
  "idempotency_key": "ce29cbae-2cf3-4ec9-a135-e874de51ddae"
}
```

The response includes:

```json
{
  "id": "TOP_UP_ID",
  "team_id": "TEAM_UUID",
  "amount_minor": 10000,
  "currency": "eur",
  "status": "requires_payment_method",
  "stripe_status": "requires_payment_method",
  "payment_intent_id": "pi_...",
  "client_secret": "pi_..._secret_...",
  "publishable_key": "pk_test_..."
}
```

4. Present Stripe PaymentSheet (mobile) or confirm with Stripe.js (web), using `client_secret`. Stripe handles card entry and any bank authentication. Never send card details to this API or log the client secret.
5. After confirmation, poll `GET /payments/top-ups/TOP_UP_ID` every 2–3 seconds while the screen is open, backing off after a short wait. Show completion when `status` is **`credited`**. Refresh the existing team balance and invoice history. Payment reconciliation does not depend on polling or the app staying open.

A credited response includes `invoice_id`, `paid_at`, `credited_at`, `balance_before`, and `balance_after`. `email_sent_at` appears after the confirmation email is sent. `balance_after` is the balance at this deposit, not a live balance after later charges.

On network errors/`502`, repeat the POST with the **same key and amount**. Do not create another attempt merely because the response was lost. A changed amount with the same key returns `409`; a deliberate new top-up needs a new key. Rarely a concurrent request returns `status=creating` without a secret: briefly wait and repeat the same POST. `requires_action`/`processing` are not credited; use the Stripe SDK to finish required authentication. A declined card can be retried on the same PaymentIntent.

## Invoices and email

A successful top-up creates one `Rechnung` with `status=bezahlt`, `topay=0`, `payment_source=stripe`, and a `stripe_deposit` object containing the payment/charge references, amount, date, resulting balance, and `livemode`. This is an **ÖKFB deposit receipt**, not a Stripe Billing Invoice/PDF. Existing manually created entries remain supported; older records do not need rewriting.

The email goes to the team's account owner email captured when the top-up starts. It includes team name, deposit amount, Vienna payment time, receipt number, PaymentIntent ID, and before/after balance. Email failure retries independently and never credits again. SMTP delivery is at-least-once: a crash immediately after sending can repeat the email. Stripe may additionally send its own payment receipt.

Stripe entries cannot be completed, edited, deleted, or refunded through old invoice actions. Existing invoice reads under `/app/rechnungen` and `/teams/:id/rechungen` now require an owner/admin token. `/finanzen`, the legacy `/teams/:id/topup/:amount`, and generic `/teams` POST/PATCH routes require an admin token; these routes accept direct balance changes and must not bypass Stripe payment. Existing admin manual top-ups retain their behavior.

## Recovery and testing

`team_stripe_topups` tracks each attempt, applied credit, receipt, email delivery, `lastError`, and `needsReview`. `team_stripe_events` is the durable webhook inbox. An atomic team balance write includes a temporary recovery marker; the marker is removed only after the receipt and permanent applied state exist. Existing team balance saves apply their changes atomically so a concurrent save cannot overwrite a Stripe deposit.

If creation was interrupted and neither a PaymentIntent nor Checkout Session ID is known after 23 hours, the attempt becomes `needs_review`. Inspect Stripe by `metadata.top_up_id` before allowing another payment: expired Stripe idempotency keys must not create duplicate charges. Re-delivering a genuine matching Stripe webhook reconnects the existing payment. Refunds/disputes initiated in the Stripe Dashboard require administrator reconciliation; this feature does not initiate refunds or withdrawals.

For an end-to-end sandbox check, create a payment through this API and pay through Checkout or the SDK with `4242 4242 4242 4242`, any future expiry and any CVC. Before paying, verify confirmation returns `202`; after paying, wait for `200`, one balance change, one paid invoice, and the email. A generic `stripe trigger payment_intent.succeeded` has no matching ÖKFB metadata and intentionally does not credit a team. Replay the genuine Checkout and PaymentIntent webhooks to confirm no additional credit. Automated tests use mocked Stripe/SMTP responses and a real isolated MongoDB; a sandbox payment is still needed to verify your actual account/keys/webhook delivery.

Local automated tests (use a disposable MongoDB on loopback):

```sh
STRIPE_TEST_MONGO_PORT=27028 swift test --filter TeamTopUpTests
```

References: [Checkout Sessions](https://docs.stripe.com/api/checkout/sessions/create), [Checkout fulfillment and delayed payments](https://docs.stripe.com/checkout/fulfillment), [Stripe PaymentIntents](https://docs.stripe.com/payments/payment-intents), [webhooks](https://docs.stripe.com/webhooks), [test cards](https://docs.stripe.com/testing).
