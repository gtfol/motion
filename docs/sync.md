# Optional cloud sync

Motion uses its own Supabase project, `ljjzzspdphikxmubscef`, named **motion**, under `motion@gtfol.dev`’s organization. Capsule’s users, data and credentials are not reused. The native app uses Google OAuth with Supabase PKCE and a namespaced Keychain session. No Apple or email sign-in UI is included. Email authentication is disabled in the hosted project; Apple and anonymous authentication remain disabled.

## Data and account boundaries

- Syncs completed workout documents (sets, exercise snapshots and recorded heart rate), catalog exercises, routines, units, default rest and optional age.
- Active workouts/rest timers, strap pairings and HealthKit permissions/export state remain local. Restoring a workout never exports it to Apple Health automatically. Sleep/Zepp data is not implemented.
- Guest storage retains `vitals.store`. Each account has a separate directory and merge journal. First sign-in offers to copy the guest log; skipping leaves it untouched. Sign-out retains the account’s offline edits for the next login. Switching is blocked during an active workout or Health export.
- Auth tokens are stored in Keychain under `dev.gtfol.vitals.motion-auth`; the merge journal uses iOS file protection. The project URL and publishable key in Info.plist are public client configuration. Service-role credentials must never enter the app or repository.

## Merge protocol

`motion_records` stores one document or durable deletion marker per `(owner, kind, id)`. Server revisions order changes; phone clocks do not choose winners. Writes compare the last acknowledged revision and include a persisted mutation UUID, so a lost acknowledgement cannot duplicate a workout. An account-level transaction lock precedes sequence allocation, preventing a pull cursor from skipping late commits with older revisions.

Each phone keeps acknowledged documents, pending mutation identities, unresolved local/remote copies and a pull cursor. It saves pending requests before uploading and advances the merge base only after applying a local transaction. Edits made during network requests survive acknowledgement. Conflicting edits/deletions pause that document and appear in Settings with a comparison and explicit choice. Other documents continue syncing. Deleting an exercise intentionally removes it from routines; past workouts retain snapshots.

Writes go only through `motion_apply`; authenticated clients cannot directly change the tables or sequence. RPCs verify `auth.uid()` and only return that account’s data. Table reads also use RLS. Account deletion verifies the caller with Supabase Auth, ignores any submitted user ID, then deletes that account; foreign keys cascade its records and mutation history. The endpoint cannot erase offline copies held by another device or Apple Health copies.

## Deployment

1. Apply `supabase/migrations` in order to Motion’s project. The initial migration was applied through the project SQL editor on October 1, 2026.
2. Deploy `supabase/functions/delete-account` with the configuration in `supabase/config.toml`. It performs its own current-user verification; legacy-secret-only gateway verification is disabled for compatibility with current JWT signing keys.
3. Configure a Google OAuth **Web application** client with callback `https://ljjzzspdphikxmubscef.supabase.co/auth/v1/callback`. Enter its client ID (ending in `.apps.googleusercontent.com`) and matching client secret in Supabase, enable Google, and preserve nonce checks. An email address or database password is not an OAuth credential. Keep unused email authentication disabled.
4. Allow only the native redirect `dev.gtfol.vitals://auth/callback` for the app. The registered bundle ID stays unchanged from TestFlight.
5. Verify real Google sign-in and a restore on a separate installation, account switching, offline retry, and deletion using a disposable account before a sync TestFlight upload. Update App Store privacy declarations to cover optional account-linked fitness/heart-rate data and Google account information.

## Verification

- Core merge scenarios run with `swift test`.
- `SyncPersistenceTests` uses two independent on-disk stores and a simulated server to check a full workout/routine/heart-rate restore, offline queue restart, lost acknowledgements, deletion conflicts, child edits and local Health export state, active-workout exclusion and wrong-account journal rejection.
- `supabase/tests/bootstrap.sql`, the migration, and `supabase/tests/sync.sql` run in order in an **empty disposable PostgreSQL database only**. Never apply the bootstrap to Supabase or an existing database. Assertions cover account isolation, RLS, denied direct writes, compare-and-swap, retries, tombstones, cursors and account-delete cascades.
- `deno test --allow-env supabase/functions/delete-account/index_test.ts` checks missing/invalid authentication and that a submitted victim ID cannot select the deleted account. Requests are mocked; no real account is deleted by these tests.
- The deployed account-deletion endpoint has been checked with missing and invalid tokens; both return 401. The Data API was enabled on October 1, 2026, after Allen's approval. Anonymous reads of `motion_records` and calls to `motion_pull` now return 401 / SQLSTATE 42501 (permission denied), replacing the previous PGRST002 service error. Live Google sign-in and a real authenticated restore remain pending Google provider configuration.
