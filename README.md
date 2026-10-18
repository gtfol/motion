# motion

Health tracking for workouts, heart rate and sleep, with Amazfit Helio Strap support.

This repository follows [Capsule](https://github.com/gtfol/capsule)’s layout: the iPhone app and web service live together with independent build tools.

| Directory | Purpose | Setup |
| --- | --- | --- |
| `apps/ios` | SwiftUI iPhone app, local workout log, Bluetooth and Apple Health | [iPhone README](apps/ios/README.md) |
| `apps/web` | Next.js website, Google sign-in and account sync API | [Web README](apps/web/README.md) |
| `docs` | Shared sync architecture and repository notes | [Sync](docs/sync.md), [repository layout](docs/repository-migration.md) |
| `supabase` | Historical Supabase Auth sync migrations and tests, retained for existing data | [Sync history](docs/sync.md) |

## Development

Open `apps/ios/Motion.xcodeproj` in Xcode. For core tests, run `swift test --package-path apps/ios`.

For the web service, run `npm ci`, `npm run typecheck` and `npm run build` from `apps/web`. Database tests use a local disposable PostgreSQL database; see the web README. There is no root dependency install or shared JavaScript workspace.

GitHub Actions checks each app from its own directory. Vercel’s existing **motion** project serves [motion.gtfol.dev](https://motion.gtfol.dev), with `apps/web` as its root and `main` as its production branch.

## Data and identity

Google sign-in goes through Motion’s web service. Account data is stored in the private `motion_backend` schema in Motion’s Supabase PostgreSQL project. The iPhone app remains usable offline; sleep and overnight strap measurements are currently stored locally.

The registered iPhone bundle identifier remains `dev.gtfol.vitals`. The Xcode project, targets, scheme, source folders and core package use Motion. Compatibility identifiers (local stores, SwiftData model namespace/schema, authentication callbacks, Keychain services and HealthKit sync IDs) stay stable so existing installations keep their data and sign-in.
