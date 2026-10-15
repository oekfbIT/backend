# New team registration

The homepage (`oekfb_hompage`), Livescore (`Development/livescore`) and ÖKFB Client admin (`PUBLIC_REPO/FRONTEND/oekfbFrontEndClient`) share the backend `TeamRegistration` record. Submission does not create a team. AdminGateway is not part of this change.

## Lifecycle

| Stage | Behavior | Communication |
| --- | --- | --- |
| Initial request | Homepage creates a draft; Livescore requires a verified team account and accepts an application without files. | Welcome email to the primary contact; notification to the office. |
| Verification | App account links expire after 24 hours; repeated clicks are safe within that window. Credential-authenticated resend is available with a 60-second cooldown. | Verification link opens the homepage verification screen. |
| Documents requested | Admin sends an invitation. The link is scoped to one registration, expires after 30 days and returns upload flags, not private document URLs. | Contract download and signed upload link. |
| Documents submitted | Both contacts, both IDs and signed contract are retained. Partial saves are supported; completed documents move draft to verified. | Receipt to applicant and notice to office when documents are complete. |
| League assigned | Price is calculated once, including deposit. A resend does not debit the registration again. | Payment information to primary contact. |
| Payment recorded | Atomic credit with a request receipt; retrying the same payment ID cannot credit twice. Non-negative balance moves to paid. | Payment confirmation. Delivery failure does not make the payment fail. |
| Admin approval | Requires both contacts, IDs, contract, league and finite non-negative balance. Creates and links one team with a stable ID. | New accounts receive generated credentials; existing accounts keep their password and receive approval instructions. |
| Rejection | No team is created; applicant editing is closed. | Rejection email. |

A verified Livescore account can continue pending homepage registrations matching its verified email. Email matching never resets an existing account password. Finalized applications cannot be edited by the applicant. Old approved records missing their team link have an explicit admin repair action; ambiguous existing teams require manual review.

## Operations

- `REGISTRATION_CONTRACT_URL`: HTTPS URL of the current contract PDF, shared by app downloads and upload-request emails.
- `EMAIL_ACTION_SECRET`: at least 32 characters. Preserve an existing secret; rotating it invalidates existing email-action links.
- `REGISTRATION_WEB_BASE_URL`: defaults to `https://www.oekfb.eu`; local development can use `http://localhost:1234`.
- `REGISTRATION_ADMIN_EMAIL`: defaults to `office@oekfb.eu`.
- Existing SMTP and Firebase settings are still required. No live email or Firebase upload is performed by the automated tests.

Local `.env` now contains the previously missing contract URL, signing secret and localhost link base. Production configuration is not changed. Restart the API to load settings and compiled changes. The homepage preview can run independently, but submissions and email-action pages need the API on its configured origin (localhost:8080 by default).

New optional metadata (`documentsRequestedAt`, `emailDeliveries`) is compatible with existing MongoDB registration documents. Payment receipts are stored atomically in the same document. Admin overview shows failed/pending email delivery and offers retry actions. No automatic retry worker is added; an interrupted or failed delivery remains visible for admin retry.

## Relevant endpoints

- `POST /client/homepage/register`
- `POST /app/application/request`, `POST /app/application/resendVerification`
- `GET /app/application/user/verify/:code`, `GET /app/application/contract`
- `POST /app/application/apply`, `GET/PATCH /app/application/registrations/:registrationId`
- `GET/POST /email-actions/registration/:id` with `X-Email-Action-Token`
- `POST /admin/registrations/requestDocuments/:id`
- `POST /admin/registrations/resendWelcome/:id`, `resendPayment/:id`, `resendNotification/:id/:event`
- Existing admin confirmation, league, payment and rejection actions; legacy root actions delegate to the same handlers.

Homepage routes: `/#/register`, `/#/registration/:id?token=...`, `/#/app/application/user/verify/:id`; the old `/#/app/user/verify/:id` alias remains supported.

## Validation

- `REGISTRATION_TEST_MONGO_PORT=<disposable-local-port> swift test --filter RegistrationFlowTests` creates and drops unique test databases. Mail and file transports are stubbed. Never point these tests at a production database.
- Admin: `CI=true npm test -- --watchAll=false --runInBand`; `npm run build`.
- Homepage: Parcel build; `node --test scripts/analytics.test.mjs`; browser checks for desktop/mobile layout, required fields and incomplete upload links.
- Livescore: `node scripts/test-registration.cjs`. The full project type-check has pre-existing errors; comparison of changed registration files against their original versions introduced no new diagnostics.
