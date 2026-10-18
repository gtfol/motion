# Repository layout

Motion follows Capsule’s `apps/ios` and `apps/web` structure. Both apps remain in `gtfol/motion` and keep independent build systems.

| Previous path | Current path |
| --- | --- |
| `Vitals`, `Vitals.xcodeproj`, `VitalsTests`, `VitalsUITests` | `apps/ios/Motion`, `apps/ios/Motion.xcodeproj`, `apps/ios/MotionTests`, `apps/ios/MotionUITests` |
| `Package.swift`, `Packages`, `scripts` | `apps/ios/` with the same names |
| iPhone README and design, verification and Helio notes | `apps/ios/README.md` and `apps/ios/docs/` |
| `web` | `apps/web` |
| `docs/sync.md`, `supabase` | Unchanged at the repository root |

## Deployment

Keep the existing Vercel **motion** project, domain and environment variables. Its Git repository is `gtfol/motion`, production branch is `main`, and Root Directory is `apps/web`. The app’s `vercel.json` selects Next.js. This move requires no database migration or new Vercel/Supabase project.

The iOS project generator, package references and test script resolve from `apps/ios`. GitHub Actions uses the new working directories and artifact paths. The subsequent Motion naming cleanup renames the project, targets, scheme, source folders and core package. The registered bundle ID, internal SwiftData model namespace/schema, local store paths, Keychain services, authentication callback and HealthKit sync identifiers remain unchanged so existing installations retain their data and sign-in.

## Local checkouts

Only tracked files moved. Local ignored files such as environment files, Vercel links, dependencies and build caches were left untouched. Reinstall dependencies in the new app directory when needed; manage any private local configuration separately. Do not commit credentials or old generated build artifacts.

The existing main rename commit was reconciled without changing the newer app source before moving the folders. The feature history is retained in the merge.
