# vitals

A training log for iPhone: start a strength session, log exercises and sets, watch live heart rate from an Amazfit Helio Strap, finish once. The lift log works without a strap and without Apple Health.

Native SwiftUI + SwiftData, iOS 17+, iPhone only. Apple frameworks only (SwiftUI, SwiftData, Charts, CoreBluetooth, HealthKit): no packages, no backend, no account, no analytics, no network calls. Everything works offline.

## Build and run

1. Open `Vitals.xcodeproj` in Xcode 26.6 or newer and select the **Vitals** scheme.
2. Choose an iPhone simulator, or a physical iPhone for Bluetooth and HealthKit. For a device, pick your team under Signing & Capabilities. The HealthKit capability comes from `Vitals/Vitals.entitlements`.
3. Run.

The bundle identifier is a project setting, `VITALS_BUNDLE_IDENTIFIER = dev.gtfol.vitals`, not a settled App Store identifier. Change it in `scripts/generate-project.py` (`BUNDLE_IDENTIFIER`), then regenerate the project. The complete generated project is committed; no generation step is needed to build.

## The workout flow

- **Train** starts a strength session from an empty log or a saved routine, or a heart-rate-only session (running, walking, cycling, other). A session starts whether or not the strap is connected and whatever the Apple Health access. Only one session can be active; relaunching never starts a second one.
- **Set logging.** Add exercises from a small, editable local catalog (name plus optional muscle/category), search recent ones, or create one by typing its name. Reorder exercises. Each set has an order, kind (working or warm-up), reps, load, a done flag and completion time. A new set copies the preceding set's reps and load and is never marked done automatically. Tap a set's number to switch warm-up/working or delete it. Last session's sets appear beside each set, with prior bests above the table.
- **Rest.** Marking a set done starts a rest clock with the default from Settings, with +30s and skip. It is computed from the completion time, so it stays correct after the screen locks or vitals relaunches. There are no notifications in v1.
- **Heart rate.** A compact strip above the set log shows workout time, connection state, last sample time, large live BPM, average and maximum, and a small chart. Heart rate never blocks set entry. A dropout shows as a gap; vitals reconnects on its own and never fills in missing readings.
- **Finish.** Review duration, exercises, completed working sets, volume, new bests and heart rate. vitals saves locally first, then writes one workout to Apple Health if allowed, and shows the two results separately. A failed export can be retried without creating a duplicate.
- **History** lists finished sessions with date, activity, duration, exercise and working-set counts, volume and heart rate. Detail shows the ordered sets (editable), new-best notes, the heart-rate chart and Apple Health status with retry. Exercise history shows past sets and bests.
- **Settings:** lb/kg, default rest, optional age for an approximate zone tint, the strap (choose, reconnect, forget, battery when reported), and the Apple Health explanation.

## Calculations

Loads are stored in kilograms (`WeightUnit.kilograms(fromDisplayed:)`, 1 lb = 0.45359237 kg exactly) and shown in the chosen unit, so switching units never changes a logged set. Zero load is shown as bodyweight (`bw`), not as zero effort.

- **Volume** is reps × external load over completed working sets. Warm-ups, incomplete sets and bodyweight are excluded; it is never presented as total bodyweight work.
- **Records** are computed from the persisted log every time, so editing or deleting a set updates them. Two kinds: heaviest completed working-set load, and best Epley estimated 1RM (load × (1 + reps/30) for 2–10 reps; a single is its own estimate). A first weighted session sets a baseline rather than a record; ties are not records; only the session's best set is marked.
- **Bodyweight exercises** (a flag on the exercise) are tracked and shown in history but not compared for records, including sets with added load, until added-load semantics are designed. Zero-load sets on any exercise are never compared.

These live in `Vitals/Core`, which is plain Foundation and has its own tests.

## Helio Strap over Bluetooth

In Zepp: Device → Helio Strap → Health Monitoring → turn on **Heart Rate Push**, then fully quit Zepp while training, since it can hold the strap's connection. Zepp doesn't need to be open for vitals to record.

- vitals uses the standard Heart Rate service (`0x180D`) and Heart Rate Measurement (`0x2A37`): 8- or 16-bit BPM, sensor contact, energy (ignored) and optional RR intervals. Raw RR values (1/1024 s) are stored with each sample, without HRV analysis. According to [HelioBar](https://github.com/TirthCodes/HelioBar)'s notes, the Helio currently sends BPM without RR intervals. A reading of 0 means "no reading" and isn't stored.
- Battery (`0x180F`/`0x2A19`) is read and subscribed when present. A missing battery service is not a connection failure.
- You choose the strap from a list; vitals stores its CoreBluetooth identifier and connects only to that device. It never picks a nearby heart-rate device on its own. Bluetooth is only started at launch if a strap was chosen before, so people without a strap never see a Bluetooth prompt.
- Reconnection uses a pending `connect`, which doesn't time out: iOS completes it when the strap is back in range. The central manager has a restore identifier and the app declares the `bluetooth-central` background mode.
- States shown: searching, connected (with last sample time and battery), reconnecting (with how long heart rate has been missing), no heart-rate service (Heart Rate Push off), Bluetooth off, Bluetooth access denied.

What iOS doesn't allow: after a force-quit (swiping vitals away), iOS doesn't relaunch it for Bluetooth, so nothing is recorded until you open vitals again. If iOS terminates vitals in the background, state restoration may relaunch it when the strap sends data, but that is up to iOS. Either way the missing time is a gap in the chart, and the relaunch prompt says heart rate isn't recorded while vitals is closed.

Samples are inserted as they arrive and saved to disk in batches at most five seconds apart (and with every set change), so up to about five seconds of the latest samples can be lost if iOS ends the app.

## Apple Health, with iOS 17 as the deployment target

HealthKit receives a copy of each finished workout and the heart-rate samples vitals received. It never owns sets; the local log is the record.

- vitals uses `HKWorkoutBuilder` (iOS 12+): `beginCollection(at:)`, `addSamples(_:)` with timestamped heart-rate `HKQuantitySample`s from the strap, `addMetadata(_:)`, `endCollection(at:)`, `finishWorkout()`. The activity type follows the session (traditional strength training, running, walking, cycling, other); strength is marked indoor.
- `HKWorkoutSession(healthStore:configuration:)` and `HKLiveWorkoutBuilder` on iPhone are iOS 26 APIs ([WWDC25 session 322](https://developer.apple.com/videos/play/wwdc2025/322/)), so they aren't used. There is no optional iOS 26 path in v1. The deployment target stays iOS 17.
- Permissions: write workouts and heart rate; read workouts only, to look for an earlier save before retrying. Nothing else is requested; no energy is written.
- Idempotent retry: the workout carries `HKMetadataKeySyncIdentifier` (`vitals.workout.<session id>`) and a sync version, and every heart-rate sample carries its own. HealthKit ignores a repeated save with the same identifier and version ([WWDC20 session 10184](https://developer.apple.com/videos/play/wwdc2020/10184/)). A retry first queries for the workout by that identifier. The "saving" state is stored before anything is written, so an interrupted export is found at launch and marked retryable.
- States: not exported yet, saving, saved, not saved (retry), not allowed, unavailable. A session saved with the Health data unavailable or access denied remains fully usable.
- A session with no heart-rate samples is still a valid workout; one with no completed sets is saved as a heart-rate workout.

Limits on iOS 17: the builder writes a workout after the fact, not a live workout session, so vitals makes no claim about activity-ring or calorie credit. `finishWorkout()` can succeed but return no workout while the iPhone is locked; vitals then records the save without the Health workout's identifier. Samples added to a builder are saved as they're added and aren't removed if an attempt fails; their sync identifiers keep a retry from duplicating them, but after a failed first attempt they may not be linked to the saved workout. This hasn't been observed on a device yet; see [verification](docs/verification.md).

## Local data

One SwiftData store (`Application Support/vitals.store`, CloudKit off) owns the catalog, routines, the active session, history and settings. Models: `Exercise`, `Routine`, `RoutineExercise`, `WorkoutSession`, `SessionExercise`, `LoggedSet`, `HRSample`, plus `AppPreferences`. Every record has a stable UUID; ordered children carry an explicit `order`. The schema is versioned (`VitalsSchemaV1`) for future migrations.

Delete rules are deliberate:

| Relationship | Rule | Why |
| --- | --- | --- |
| Session → exercises → sets | cascade | deleting a session removes its log |
| Session → heart-rate samples | cascade | samples belong to one session |
| Routine → routine exercises | cascade | a routine owns its template |
| Exercise → routine exercises | cascade | a deleted exercise leaves routines |
| Exercise → session exercises | nullify | history keeps the name snapshot and exercise ID |

Routines and sessions are never linked by a relationship: starting a routine copies it, so editing the workout can't rewrite the routine. The active session is saved at every set and state change, including the rest timer and a heartbeat every 30 seconds, which is used to finish an interrupted session at the time vitals last ran rather than at relaunch.

## Design

vitals follows gtfol's design standard ([gtfol/ai DESIGN.md](https://github.com/gtfol/ai/blob/d42dc2ed9964fef2f2aa95149783fcaa58026e82/DESIGN.md)), which is based on freewrite and capsule, and capsule's iPhone app. It's a written standard with starting color values, not a published token package. vitals uses its dark column: black canvas, #eeeeee text, #aaaaaa secondary text, #2c2c2c dividers, and #d4b26a/#ef9696 for caution. Lato Regular is bundled under the [SIL Open Font License](Vitals/Resources/Lato-OFL.txt) with Dynamic Type, as in capsule and freewrite; its figures are tabular, so changing numbers don't shift. Copy is lowercase, with other companies' product names capitalized as capsule does.

From capsule and freewrite: the quiet text bottom navigation (train · history · settings), inline titles, open sections without cards, 20 pt gutters, 44 pt touch targets, capsule's 2 pt-radius primary button and information popovers, and freewrite's timestamp-based timer. vitals' own additions, documented as such: larger numeric sizes for live BPM (56 pt) and set entry (20 pt), and an approximate-zone tint that only colors zones 4 and 5 and always writes the zone out. vitals is dark-only, like capsule. See [design notes](docs/design.md) for what was taken from capsule and what wasn't.

## Tests

```sh
swift test                 # core calculations, parsing, timers (macOS or Linux)
scripts/test-ios.sh        # simulator and device builds, then XCTest on an iPhone simulator (needs Xcode)
```

`swift test` runs `VitalsTests/CoreTests.swift` against `Vitals/Core` through `Package.swift`. The Xcode test target adds SwiftData persistence and coordinator tests (reopening an on-disk store, routine copies, delete rules, records after edits, relaunch recovery, export retry). `VitalsUITests` drives the real interface through a strength workout (start, add exercises, type loads and reps, complete sets, rest, finish, history, switch to kg, exercise history) and keeps a screenshot of each screen. In debug builds, the `-ui-testing` launch argument gives it a throwaway store, no Bluetooth, and Apple Health reported as unavailable so no permission sheet appears. GitHub Actions runs all of it on macOS, uploads the screenshots, and checks that the committed project matches the generator.

None of it exercises a real strap, Bluetooth background behavior or real HealthKit writes. The device checklist is in [docs/verification.md](docs/verification.md).

## Project layout

- `Vitals/Core`: units, set math, records, heart-rate parsing and statistics, rest timer, session and export values. Foundation only.
- `Vitals/Persistence`: SwiftData models, schema, and `WorkoutStore`, the only place that changes the log.
- `Vitals/Services`: `HeartRateMonitor` (CoreBluetooth), `HealthKitExporter` (HealthKit), and `SessionCoordinator`, which ties logging, the strap and Health together.
- `Vitals/UI`: train, history, settings, and shared style.
- `VitalsTests`: core, persistence and coordinator tests. `VitalsUITests`: the workout flow with screenshots.
- `scripts/generate-project.py`: standard-library-only project generator, adapted from capsule's. `scripts/make-icon.py` renders the app icon.

Out of scope for v1: Zepp/Huami sync, sleep, HRV and recovery, GPS and routes, Apple Watch, cloud sync and accounts, nutrition, program builders, plate math, RPE, notifications, widgets.
