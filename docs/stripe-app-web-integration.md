# Team top-ups: app and web integration

## Connection and authentication

Production API base URL: `https://api.oekfb.eu`.
For a sandbox build, use the URL of your sandbox backend. The backend's `STRIPE_MODE` selects the Stripe account; the client cannot override it.

Every endpoint in this guide requires the existing login token:

```http
Authorization: Bearer YOUR_LOGIN_TOKEN
Content-Type: application/json
```

Team accounts can access their own teams; admins can access any team. JSON field names use **snake_case**, dates are **ISO 8601**, and optional fields may be absent. Payment amounts are integer **EUR cents**: `10000` means €100.00. Existing team balances and invoice totals are in euros.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/payments/config` | Selected Stripe mode, publishable key, limits and Checkout availability |
| POST | `/payments/teams/:teamID/top-ups/checkout` | Create/resume a hosted payment link |
| POST | `/payments/teams/:teamID/top-ups` | Create/resume a PaymentIntent for the Stripe client SDK |
| GET | `/payments/top-ups/:topUpID/confirmation` | Confirm payment and balance credit using HTTP status codes |
| GET | `/payments/top-ups/:topUpID` | Read the attempt's current state |
| GET | `/payments/teams/:teamID/invoices` | Paginated finance history |

Use the team's UUID as `teamID`. Use the creation response's `id` as `topUpID`, not the Stripe `pi_...` or `cs_...` identifier.

## 1. Load payment configuration

```http
GET /payments/config
```

Example response (limits depend on backend configuration):

```json
{
  "publishable_key": "pk_test_...",
  "currency": "eur",
  "minimum_amount_minor": 50,
  "maximum_amount_minor": 500000,
  "livemode": false,
  "stripe_mode": "sandbox",
  "checkout_enabled": true
}
```

Validate the entered amount against these limits. Show a test-mode indicator when `livemode` is false. Only offer the hosted link option when `checkout_enabled` is true. Secret API keys and webhook secrets belong exclusively on the backend.

## 2A. Hosted payment link — simplest for web and mobile

1. The user chooses an amount and presses **Top up**.
2. Generate a UUID as the `idempotency_key`. Persist the key, amount, team ID, backend URL, and chosen flow **before sending the request**. Reuse them if the request times out or the app restarts.
3. Send:

```http
POST /payments/teams/TEAM_UUID/top-ups/checkout

{
  "amount_minor": 10000,
  "idempotency_key": "ce29cbae-2cf3-4ec9-a135-e874de51ddae"
}
```

Typical response, with optional fields omitted:

```json
{
  "id": "TOP_UP_ID",
  "team_id": "TEAM_UUID",
  "amount_minor": 10000,
  "currency": "eur",
  "status": "open",
  "stripe_status": "open",
  "payment_flow": "checkout",
  "checkout_session_id": "cs_test_...",
  "checkout_status": "open",
  "checkout_url": "https://checkout.stripe.com/...",
  "checkout_expires_at": "2026-09-16T12:00:00Z",
  "publishable_key": "pk_test_..."
}
```

4. Save `id`. On web, navigate to `checkout_url`; on mobile, open it in the system browser. This flow needs no Stripe client SDK.
5. Stripe redirects to the backend-configured success/cancel URL with `?top_up_id=TOP_UP_ID` appended (or adds it to the existing query). Implement those return pages in your website. A mobile app can resume checking its saved attempt when it becomes active; you can also configure your own HTTPS universal/app link return page.
6. Check confirmation as described below. The redirect itself is not payment confirmation.

If creation returns `status: "creating"` without a URL, briefly wait and retry the same POST with the same key. If it returns `credited`, show the completed result instead of opening Checkout. Expired/completed sessions do not return an open payment URL.

Closing Checkout or returning via the cancel page does not cancel the payment. Check the backend before starting another attempt. An open link can be reused until it expires, normally after 24 hours.

### Web request example

`attempt` below is the object your UI has already persisted. The example intentionally leaves retry decisions to the UI so a failed request cannot silently start a second payment.

```js
async function openTopUpCheckout(apiBase, token, teamId, attempt) {
  const response = await fetch(
    `${apiBase}/payments/teams/${encodeURIComponent(teamId)}/top-ups/checkout`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        amount_minor: attempt.amountMinor,
        idempotency_key: attempt.idempotencyKey
      })
    }
  );
  const data = await response.json();
  if (!response.ok) throw new Error(data.reason ?? `HTTP ${response.status}`);

  // Persist this alongside the original attempt before navigating away.
  sessionStorage.setItem("activeTopUpId", data.id);
  if (data.status === "credited") return data;
  if (data.checkout_url) window.location.assign(data.checkout_url);
  return data; // If still creating, retry the same attempt after a short wait.
}
```

For a website on a different origin, the backend's CORS policy must allow that origin and the `Authorization`/`Content-Type` headers.

## 2B. Stripe SDK — embedded web form or native PaymentSheet

1. Initialize your Stripe client SDK with `/payments/config` → `publishable_key`.
2. Persist a new attempt as above, using the SDK flow.
3. POST the same `{ "amount_minor": 10000, "idempotency_key": "UUID" }` body to `/payments/teams/TEAM_UUID/top-ups`.
4. Read `id` and `client_secret`. Present the PaymentIntent through Stripe.js/Elements on web or PaymentSheet on mobile. Let the SDK handle card entry and required bank authentication. Do not send card details to this backend.
5. After the SDK finishes, check the backend confirmation endpoint. An SDK success callback alone does not confirm that the team balance has been credited.

The response includes `payment_flow: "sdk"`, `payment_intent_id`, and usually `status: "requires_payment_method"` initially. If the secret is temporarily absent while `creating`, retry the same POST. A credited attempt no longer exposes its client secret. Never log client secrets or put them into your own return-page URLs.

## 3. Wait for confirmed credit

```http
GET /payments/top-ups/TOP_UP_ID/confirmation
```

Poll about every 3 seconds while the screen is open. After roughly a minute, show “Payment still processing”, slow down polling, and allow the user to leave. Resume checking the saved attempt later. Stop polling when the screen closes; backend reconciliation continues independently.

| HTTP status | Meaning | UI action |
| --- | --- | --- |
| **200** | `status: "credited"`; payment verified, balance credited and invoice recorded | Show success; refresh balance and finance history |
| **202** | Payment or balance update still pending | Keep waiting; response includes `Retry-After: 3` |
| **402** | `payment_failed`; Stripe reported a failed attempt | Show failure; the user may retry the same open link/PaymentIntent |
| **410** | Session expired or payment canceled | Offer a deliberate new attempt with a new key |
| **409** | `needs_review` | Ask the user to contact support; do not automatically charge again |

These outcomes return the top-up JSON, rather than a generic error object. Authentication and missing-record errors use the normal API error format. In JavaScript, `response.ok` is **true for 202**, so check `response.status === 200 && data.status === "credited"` explicitly.

A credited response adds:

```json
{
  "status": "credited",
  "invoice_id": "INVOICE_UUID",
  "payment_intent_id": "pi_...",
  "paid_at": "2026-09-15T12:00:00Z",
  "credited_at": "2026-09-15T12:00:01Z",
  "balance_before": -50,
  "balance_after": 50
}
```

This example is a €100 deposit against a −€50 balance. `balance_after` is the balance immediately after that deposit; fetch your existing team data for its current balance. `email_sent_at` appears when the backend sends the confirmation email. No additional invoice, balance-update, or email request is needed from the client.

`GET /payments/top-ups/:id` returns the same state with **200 whenever the record is readable**, even if payment is pending. Use `/confirmation` when you want HTTP codes to represent the outcome.

## 4. Finance history

```http
GET /payments/teams/TEAM_UUID/invoices?page=1&per=20
GET /payments/teams/TEAM_UUID/invoices?source=stripe&page=1&per=20
GET /payments/teams/TEAM_UUID/invoices?source=manual&page=1&per=20
```

The result is `{ "items": [...], "metadata": { "page": 1, "per": 20, "total": 42 } }`, newest first. `per` is capped at 100.

Display the existing invoice fields (`number`, `summ`, `status`, `created`) and label the source:

- `payment_source: "stripe"`: automatic Stripe deposit; already paid (`status: "bezahlt"`, `topay: 0`).
- `payment_source: "manual"` or absent: existing manual entry.
- `stripe_deposit`: includes `top_up_id`, `payment_intent_id`, optional `charge_id`, `amount_minor`, `currency`, `paid_at`, `balance_after`, and `livemode`.

Stripe deposit records cannot be manually completed, edited, deleted, or refunded through legacy invoice actions. These are local deposit receipts, not Stripe Billing PDF invoices. Pending/failed attempts do not appear as paid invoices; keep their IDs locally to resume their status. There is currently no endpoint listing all unfinished attempts.

## Errors and retry rules

- **400:** invalid amount, key, or input. Fix the request.
- **401:** login required; reauthenticate before continuing the saved attempt.
- **403:** the user cannot access this team.
- **404:** team or attempt was not found.
- **409 on creation:** the key was already used with a different amount/flow, or the team is missing its account email. Read `reason`.
- **503:** active Stripe configuration is incomplete; Checkout additionally requires its return URLs.
- **Network timeout / 502 / other server error:** the payment may already exist. Retry creation with the **same key, amount, team, backend and endpoint**; never generate a replacement key automatically.

Disable repeated button presses while creating a payment. A new key means a new potential charge. Use a new key only for an intentional new attempt; changing between Checkout and SDK with the same key returns 409. Do not interpret link creation's 200 response as a successful deposit.

The client never calls `/payments/stripe/webhook`. Stripe sends signed notifications there; the backend verifies payment, applies one credit, records one invoice and retries email delivery in the background.

For backend deployment and Stripe Dashboard configuration, see [Stripe setup](stripe-team-topups.md).
