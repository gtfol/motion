# Motion account service

Next.js on Vercel, Google-only Better Auth, Supabase PostgreSQL storage. This follows Capsule’s login architecture with Motion’s own credentials and database. The app still uses `dev.gtfol.vitals` and returns through `dev.gtfol.vitals://auth/callback`.

## Production setup

Use the existing **motion** project in Vercel’s **gtfol** team, domain **motion.gtfol.dev**. Deploy the `web` directory (or set Root Directory to `web` for a Git connection). Keep source exposure off and never add secrets to `NEXT_PUBLIC_*` variables.

Configure production variables in Vercel:

| Variable | Value |
| --- | --- |
| `BETTER_AUTH_URL` | `https://motion.gtfol.dev` |
| `BETTER_AUTH_SECRET` | A fresh random secret with at least 32 bytes of entropy |
| `GOOGLE_CLIENT_ID` | Motion’s Google Web application client ID |
| `GOOGLE_CLIENT_SECRET` | That client’s secret |
| `DATABASE_URL` | Motion Supabase session-pooler PostgreSQL URL, using its project username and URL-encoded password |
| `DATABASE_SSL_CA` | Supabase’s CA PEM if the connection needs a private certificate chain; never disable certificate verification |

Use a dedicated Google client for Motion, not Freewrite’s client. Authorized JavaScript origin: `https://motion.gtfol.dev`. Authorized redirect URI: **`https://motion.gtfol.dev/api/auth/callback/google`**. Only basic Google identity scopes are requested. Google’s publishing/test-user settings must permit the intended TestFlight testers.

Apply `migrations/001_backend.sql` in a transaction to Motion’s database **before enabling sign-in**. The `npm run migrate` script does this with an advisory lock, checksum and migration ledger, using `DATABASE_URL` from its environment. Never run local test/bootstrap scripts against production. The migration is additive: it creates only the private `motion_backend` schema and preserves all legacy Supabase Auth/public sync data. Keep `motion_backend` out of Data API exposed schemas. The server connection must own these tables (or use an explicitly provisioned server role with equivalent access); clients never receive database access.

No migration runs during a web request or build. Missing configuration serves an honest setup message. Redeploy after adding production variables. Preview deployments should have their own disposable database/Google callback or no authentication credentials.

## Local verification

`npm ci`, `npm run typecheck`, `npm run build`.

For database tests, create a **local disposable** PostgreSQL database ending in `_test`, with `anon` and `authenticated` roles. Set `DATABASE_URL` to that database for `npm run migrate`, then `TEST_DATABASE_URL` for `npm test`. Tests refuse non-local databases and use synthetic identities only. PostgreSQL 16+ is supported. Test secrets are never production credentials.

Before TestFlight: verify real Google sign-in through the production domain, second-install restoration, offline edits/retry, switching accounts, and deletion of an explicitly disposable account. Update App Store privacy for optional account-linked fitness/heart-rate data and Google identity. A passing mocked Google redirect test is not an end-to-end sign-in test.

## Boundaries

- Native handoff codes: 2 minutes, single-use, SHA-256 PKCE, fixed callback, exact browser origin, live browser-session check, explicit account confirmation.
- Native bearer sessions: random 256-bit secrets, hashes only in PostgreSQL, one year, at most 20 connected sessions/account. Sign-out revokes the current token when online; account deletion revokes all sessions.
- Each sync transaction selects its account from the bearer and rechecks after locking the user. Deletion, token revocation and exchange take an exclusive user lock. Owner IDs are never accepted in sync bodies.
- CAS, per-account ordered revisions, durable tombstones and idempotent mutation IDs remain unchanged. Pulls continue until an empty page and respect hosting response limits.
- Google auth rate limits use the [client-address header Vercel overwrites](https://vercel.com/docs/headers/request-headers).
- All private API responses are no-store. Errors never expose SQL, OAuth secrets or connection strings. Remote database TLS always verifies certificates.
- The website bundles the selected runner icon and Lato under `public/Lato-OFL.txt`. No analytics or additional health-data collection.

## Deployment record

On October 1, 2026, Vercel verified the custom domain, and `001_backend.sql` was applied successfully through Motion’s Supabase SQL editor (SHA-256 `981466d5c9acf1bb120afcfd6ab6b17876dc41e2e1f58ae75e5b7d1368ef6c6e`). The preflight query confirmed zero legacy accounts and records. Production server credentials, web deployment and live Google/device tests remain pending.
