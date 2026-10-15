# Verification

## What has been checked

- **Daily and weekly Sleep (pending build 10):** three simulator UI scenarios pass. Daily contains only the selected night; weekly contains seven-day duration, schedule, heart-rate and breathing charts. Tests cover keeping the period switch visible while scrolling, resetting scroll position on a switch, seven-day navigation, preserving the selected date, stopping at today, pull-to-refresh and separate empty states. The existing Settings connection flow also passes. Daily, weekly and empty-state screenshots were visually inspected; measurement fixtures are synthetic.

- **Apple Health access (build 10):** 86 iOS unit tests and two Settings UI scenarios pass. The access regression covers initial authorization, immediate data refresh, repeated taps opening the access guide, opening the actual Health app, returning to Motion and refreshing again, then displaying the readable sleep data. Four authorization tests cover a previously answered request, unknown request status, status/request failures and unavailable Health. The UI test uses synthetic authorization responses and measurements; native permission choices still need a physical-device check. The flow uses Apple's [authorization request status](https://developer.apple.com/documentation/healthkit/hkhealthstore/getrequeststatusforauthorization(toshare:read:completion:)) to distinguish a new prompt from management; it never treats request completion as permission granted. Health's root URL scheme was verified in the simulator app's registered URL types and by the handoff UI test.

The first build 10 archive (`9ec996a`) passed signature and version checks, but its
upload could not read Xcode's Apple account token while the Mac was locked. It does
not include the later Apple Health access fix (`bd6616b`) or daily/weekly Sleep
views, so do not upload it.
The replacement archive stalled in Apple's asset tool while the Mac remained
locked and was cancelled. After unlocking, archive the current branch as build 10
and retry upload; no build 10 upload has succeeded. Build 9 is still the latest
successfully uploaded package below.

- **Strap transfer recovery (build 10):** 118 protocol tests, 82 iOS unit tests and the Settings UI check pass. New regressions cover zero-stage records alongside valid nights, later staging without erasing a saved night, malformed stage tables/times/overlaps with independent HR and breathing downloads, and actual local-write failure. Rejected rounds keep band history and saved cursors; content errors now identify the failing validation instead of claiming storage failed. The Settings action is named **strap settings**. The first incremental simulator build used a stale package interface; a fresh build and all targeted tests pass. The user's October 15 screenshot confirms authentication reached history processing; its generic error cannot establish the exact failed check, and a successful physical-band retry is still required. Build 9's full [CI run](https://github.com/gtfol/motion/actions/runs/38799306593) also passed.

Status as of October 15, 2026. Motion 0.1 (9), archived from `e8f8528`, uploaded successfully at 13:07 PDT with unified Sleep and setup in Settings. Apple accepted the package for processing; internal TestFlight availability is awaiting confirmation because the browser session expired. The signed Release archive passes code-signature validation and retains the `motion` phone label and `dev.gtfol.vitals` identifier. Build 8 was also uploaded successfully; build 7 remains the last browser-confirmed Testing build.

- **Unified Sleep (build 9):** 50 Foundation tests and 78 iOS unit tests pass. Seven new cases cover Helio priority, missing Health-only nights, independent metric fallback (including Health readings without Health sleep), recorder preference, invalid/awake-only samples, neighboring-date overlaps and empty data. Three Sleep UI scenarios pass: setup in Settings, automatic Health fallback with charts, and an empty page with pull-to-refresh. The initial setup check matched an inaccessible Settings control kept alive behind Sleep; the corrected visibility assertion passes. Screenshots of Settings, secure key setup, the combined charts and the empty page were visually inspected. No source tabs, refresh text button or source footer remain. Hardware sync and real Health permissions still require device verification.

- **Direct Helio sleep sync (build 8):** 117 protocol tests, 43 Foundation tests and 71 iOS unit tests pass. Eight UI scenarios passed across the full run and targeted reruns, including direct setup without Health permission, switching both source directions, the existing sleep charts, account import, routine controls, the complete workout flow and keyboard/rest layout. The new source-picker check initially used an inherited accessibility identifier; it was corrected to target the visible button and passed. The final unsigned Release device build succeeds, bundled third-party notice is present, and generated-project consistency passes. Synthetic strap tests cover authentication, wrong-key lockout, CRC/malformed-record rejection, interruption, durable storage/reload, revised-night deduplication, account/strap isolation and unreadable-storage recovery. Setup and empty-state screenshots were visually inspected. **Real strap authentication, live-HR coexistence and sleep timestamps are not yet verified.** See the [device checklist](helio-sleep.md#hardware-validation-still-required).

- **Build 8 CI:** [run 38794760798](https://github.com/gtfol/motion/actions/runs/38794760798) passed both builds, all 117 protocol tests, 43 Foundation tests, 71 iOS unit tests and seven of eight UI scenarios, including direct Helio setup. The existing workout flow timed out waiting for the saved-workout screen after a save tap; the failure snapshot still showed the enabled save button. A targeted local rerun of the unchanged workout flow passed (68.8 seconds), including save, history and unit conversion. The subsequent [full run 38797123919](https://github.com/gtfol/motion/actions/runs/38797123919) passed all builds and tests, including the workout flow, without product or test changes.

- **Sleep and breathing:** 43 Foundation tests and the full iOS suite (65 unit tests, 7 UI tests) pass; the unsigned Release device build succeeds. Foundation tests cover overlapping/duplicate records, wake-date grouping, separate naps, daylight-saving duration, missing intervals, and asleep-only averages. Simulator UI tests cover sample sleep stages/trends and empty results. The test measurements are synthetic and DEBUG-only; they do not establish which measurements Zepp exports to Apple Health. Real-device HealthKit reads remain to be checked.
- **Simpler settings:** removed the extra sign-in row and explanatory paragraphs while keeping account actions, sync errors and deletion confirmation. The first-sign-in UI regression passed after this change.
- **Routine controls:** the set and rep steppers have independent 44-point minimum heights and spacing. The simulator regression checks that they do not overlap and that each control changes its own value.
- **Workout keyboard:** simulator test confirms all bottom navigation buttons disappear while typing, the rest bar remains above the keyboard, done saves the entered load, and the navigation returns without stopping rest. Screenshot inspection confirms no extra toolbar or black gap; iOS 26's keyboard accessibility frame excludes its 17-point rounded top inset.

- **Cloud sync:** 37 core tests and 56 iOS unit tests pass locally, including seven two-store/persistence sync scenarios. The release device build passes. PostgreSQL account-isolation/CAS/tombstone tests and three Edge Function authorization tests pass, also in [backend CI](https://github.com/gtfol/motion/actions/runs/36930745337). The Data API is enabled, and unauthenticated table/RPC access is denied as expected. Production Google OAuth and native handoff were subsequently configured and verified for build 6; authenticated cross-installation verification remains on the physical-device checklist. See [sync setup](sync.md).
- **Sync build CI:** the [full iPhone workflow](https://github.com/gtfol/motion/actions/runs/36931366102) passed for `25d30a4`, including simulator/device builds and the existing workout UI test. The earlier local keyboard-focus failure did not recur in that run.
- **Iron-inspired color pass:** the simulator build and workout UI flow pass locally on iPhone 17 Pro / iOS 26.5. The flow checks set entry, completion, rest placement, saving, history and unit conversion. Eight screenshots were retained; the train, active workout and settings screens were visually inspected. The semantic text colors have at least 6.9:1 contrast against the charcoal canvas, and the primary button's dark label has 7.6:1 against its blue fill. This pass changes presentation only.
- **Runner app icon:** the selected illustration replaces the lettermark. The asset is verified as a 1024 × 1024, 8-bit opaque RGB PNG, and the simulator build passes with Xcode's app-icon asset compilation. No application logic changed. The runner icon ships in TestFlight builds 6 and 7.

Historical baseline checks:

- **Core logic, `swift test`:** 27 tests pass with Swift 6.3.3 in Swift 6 language mode with warnings as errors, on Linux (official `swift:6.3.3-noble` toolchain), and on macOS 26 in GitHub Actions. They cover unit round trips, input parsing, bodyweight text, clocks and the rest timer, Epley limits, volume, records (baseline, ties, warm-ups, incomplete, bodyweight, edits and deletes, unit switching), exercise history, previous-session pairing, workout summaries, Heart Rate Measurement parsing (8/16-bit, contact, energy, RR, truncated packets, slices), battery, statistics, gaps, chart thinning, zones, the Health payload window, sync identifiers and recovery times.
- **Bluetooth and HealthKit services:** `HeartRateMonitor` and `HealthKitExporter` were type-checked with the same compiler settings against stand-in `CoreBluetooth` and `HealthKit` modules that mirror the API signatures and `Sendable` annotations Apple documents. That found a real Swift 6 data-race error, which is fixed. Both now also compile against the iOS SDK in CI, with the same settings.
- **iOS build and XCTest:** GitHub Actions ([ios.yml](../.github/workflows/ios.yml)) checks that the committed project matches the generator, builds for the simulator and for devices (unsigned) with Xcode 26.6 on macOS 26, and tests on an iPhone 17 Pro simulator running iOS 26.5. [Run 5](https://github.com/gtfol/motion/actions/runs/36198484916) passed: 39 unit tests (27 core, 7 SwiftData persistence, 5 coordinator) and the UI workflow test.
- **UI workflow:** `WorkoutFlowUITests` starts a strength workout, adds bench press and squat by searching, types loads and reps, and completes sets. It checks that completing a set starts rest, that the rest clock sits above the tab bar rather than under it, and that a new set copies the one before it. Then it finishes, opens the workout from history, switches to kg in settings, and finds the same bench set converted (61.23 × 5) in exercise history. A screenshot of each of those eight screens is kept in the run's `screenshots` artifact. Screenshots are best effort. In [run 7](https://github.com/gtfol/motion/actions/runs/36199483971), the simulator timed out taking one while motion was idle, and that failed the test. Now a missed screenshot is recorded as an expected failure and the flow carries on.

The persistence and coordinator tests use an on-disk SwiftData store and a fake exporter. The UI test uses a throwaway store, no Bluetooth, and Apple Health reported as unavailable. None of it exercises a strap, Bluetooth, background execution or real HealthKit writes. Everything ran on iOS 26.5. motion is built for iOS 17, but it hasn't run on iOS 17 or 18 yet.

## Physical iPhone checklist

Set up first: in Zepp, Device → Helio Strap → Health Monitoring → Heart Rate Push on. Fully quit Zepp before each Bluetooth test. Test HealthKit on a real iPhone, not only the simulator.

iOS 17
- [ ] Run a strength workout, the rest timer, history and an Apple Health export on iOS 17 (an iPhone on iOS 17, or the iOS 17 simulator runtime for everything but Bluetooth). CI only runs the current simulator.

Lift log
- [ ] Log a strength workout with two exercises, completed working sets and warm-up sets. Change lb ↔ kg, use the rest timer (+30s, skip, lock the screen, reopen), finish, and reopen it from history with the same values and order.
- [ ] Repeat with no strap chosen and with Apple Health access denied. Every screen stays usable; the workout saves locally and shows "not allowed" for Apple Health.
- [ ] Start from a routine, edit the copied sets and remove an exercise; the routine is unchanged. Save a workout as a routine; edit and delete a routine.
- [ ] Log a heavier completed working set than any earlier session: "new best" shows in the workout and in exercise history. Edit it lower, then delete it: the record disappears and volume updates. Check a first-ever session (no record), a tie, a heavier warm-up, zero load and a bodyweight movement with added load (no weighted records).

Strap
- [ ] With Heart Rate Push on and Zepp quit: choose the Helio in settings, see live BPM, last sample time and battery (if reported).
- [ ] 30 minutes with the screen locked during a workout. Record how many samples arrive, and whether iOS kept delivering them.
- [ ] Walk out of range or power the strap off: the workout and sets stay, status shows reconnecting with the missing time, the chart shows a gap, and samples resume when the strap returns without anything filled in.
- [ ] Bluetooth off, then on; Bluetooth permission denied; a workout where no heart-rate packet ever arrives.
- [ ] State restoration: with a workout running, let iOS terminate motion in the background (not a force-quit) and note whether iOS relaunches it for strap data. Record the result; iOS doesn't guarantee it.
- [ ] Heart Rate Push off: status says no heart rate and points to Zepp.

Apple Health
- [ ] Connect Sleep on an iPhone with existing Health data; compare wake date, duration and stages with the selected Health source.
- [ ] Verify which Helio/Zepp sleep stages, heart-rate and respiratory-rate samples are shared with Health. Zepp-only metrics must remain unavailable, not estimated.
- [ ] Deny sleep or respiratory read access, then revoke previously allowed access: reload clears old data and explains empty results without claiming to know permission status.
- [ ] Check multiple recorders and source switching; a night must never be counted twice. Test after a time-zone change.
- [ ] With access allowed, finish a workout: exactly one workout with the right type, start and end, and the received heart-rate samples appears in the Health app.
- [ ] Force a failure (for example, finish while access is off, then turn it on) and retry: still exactly one workout. Retry again from history: nothing new is written.
- [ ] A workout with no heart-rate samples saves as a workout; a strength session with no completed sets saves as a heart-rate workout.

Relaunch
- [ ] Force-quit during a workout and reopen: the prompt offers continue or finish, the sets and start time are intact, finishing uses the last known activity time, and no second workout exists. The chart shows the closed period as a gap.

Accessibility
- [ ] VoiceOver through the set table, rest clock and heart-rate strip; the largest Dynamic Type size; a smaller iPhone.

Record results and dates here as they're checked, including any iOS limitation observed.
