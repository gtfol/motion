# Optional cloud sync

Motion uses its own Supabase project, `ljjzzspdphikxmubscef`, named **motion**, under `motion@gtfol.dev`’s organization. Capsule’s users, data and credentials are not reused. The native app uses Capsule’s approach: Google-only Better Auth on `https://motion.gtfol.dev`, followed by a single-use PKCE handoff to the iPhone. Supabase remains the PostgreSQL host; it does not handle new logins. No Apple or email sign-in UI is included. Email authentication is disabled in the hosted project; Apple and anonymous authentication remain disabled.

## Data and account boundaries

- Syncs completed workout documents (sets, exercise snapshots and recorded heart rate), catalog exercises, routines, units, default rest and optional age.
- Active workouts/rest timers, strap pairings and HealthKit permissions/export state remain local. Restoring a workout never exports it to Apple Health automatically. Sleep/Zepp data is not implemented.
- Guest storage retains `vitals.store`. Each account has a separate directory and merge journal. First sign-in offers to copy the guest log; skipping leaves it untouched. Sign-out retains the account’s offline edits for the next login. Switching is blocked during an active workout or Health export.
- Auth tokens are stored in Keychain under `dev.gtfol.vitals.motion-web-auth` with this-device-only protection; the merge journal uses iOS file protection. Info.plist contains only the public Motion server URL. Google and database credentials must never enter the app or repository.

## Merge protocol

`motion_records` stores one document or durable deletion marker per `(owner, kind, id)`. Server revisions order changes; phone clocks do not choose winners. Writes compare the last acknowledged revision and include a persisted mutation UUID, so a lost acknowledgement cannot duplicate a workout. An account-level transaction lock precedes sequence allocation, preventing a pull cursor from skipping late commits with older revisions.

Each phone keeps acknowledged documents, pending mutation identities, unresolved local/remote copies and a pull cursor. It saves pending requests before uploading and advances the merge base only after applying a local transaction. Edits made during network requests survive acknowledgement. Conflicting edits/deletions pause that document and appear in Settings with a comparison and explicit choice. Other documents continue syncing. Deleting an exercise intentionally removes it from routines; past workouts retain snapshots.

Writes go through the authenticated Vercel API. A random bearer token selects the owner on the server; client-supplied owners are rejected. Only SHA-256 hashes of native tokens and handoff codes are stored. Codes expire after two minutes, require the original verifier, recheck the browser session and can be consumed once. Native tokens expire after one year or earlier revocation; sign-out attempts remote revocation and clears the local Keychain even offline. Server queries hold an account lock so deletion cannot race an in-flight write or handoff.

The private `motion_backend` schema contains Better Auth identities, native grants/tokens and workout records. It is not a Data API schema. RLS is enabled, and public/anon/authenticated roles have no access. Better Auth UUID identities preserve the native per-account directory format. The legacy `public.motion_*` and Supabase Auth tables are retained untouched; there were no completed Google sign-ins before this transition. Never automatically map future legacy data to a new account by email.

Account deletion uses the authenticated bearer identity and a confirmation field. Foreign keys remove its browser sessions, provider credentials, native sessions, grants, records and mutation history. Other users are unaffected. Offline copies on another device and Apple Health copies cannot be remotely erased.

Pull pages are limited to 100 records and approximately 3.5 MB. The app continues until an empty page, since a short page can still have later records. Upload requests are capped at 4 MB for Vercel’s hosting limit; oversized records remain in the local log with sync failure rather than being discarded.

## Deployment

See [`web/README.md`](../web/README.md) for the Google callback, server configuration, private-schema migration and release checklist. The Supabase Auth provider and old Edge Function configuration are historical and are not used by the new native build. Do not enable a second login path.

## Verification

- Core merge scenarios run with `swift test`.
- `SyncPersistenceTests` uses two independent on-disk stores and a simulated server to check a full workout/routine/heart-rate restore, offline queue restart, lost acknowledgements, deletion conflicts, child edits and local Health export state, active-workout exclusion and wrong-account journal rejection.
- `supabase/tests/bootstrap.sql`, the migration, and `supabase/tests/sync.sql` run in order in an **empty disposable PostgreSQL database only**. Never apply the bootstrap to Supabase or an existing database. Assertions cover account isolation, RLS, denied direct writes, compare-and-swap, retries, tombstones, cursors and account-delete cascades.
- `deno test --allow-env supabase/functions/delete-account/index_test.ts` checks missing/invalid authentication and that a submitted victim ID cannot select the deleted account. Requests are mocked; no real account is deleted by these tests.
- Historical Supabase Auth verification: the deployed legacy account-deletion endpoint was checked with missing and invalid tokens; both returned 401. The Data API was enabled on October 1, 2026, after Allen's approval. Anonymous reads of `motion_records` and calls to `motion_pull` now return 401 / SQLSTATE 42501 (permission denied), replacing the previous PGRST002 service error. Supabase Google was never enabled; the new app uses the Vercel service instead.

The Vercel backend integration suite uses a disposable local PostgreSQL database and tests actual transactions, account isolation, PKCE replay/expiry, deletion/revocation, response paging and Better Auth’s Google redirect. Live Google login and production restore must still pass before uploading the new TestFlight build.
