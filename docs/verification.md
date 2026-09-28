# Verification

## What has been checked

Status as of September 25, 2026. Nothing has been installed on an iPhone yet.

- **Core logic, `swift test`:** 27 tests pass with Swift 6.3.3 in Swift 6 language mode with warnings as errors, on Linux (official `swift:6.3.3-noble` toolchain), and on macOS 26 in GitHub Actions. They cover unit round trips, input parsing, bodyweight text, clocks and the rest timer, Epley limits, volume, records (baseline, ties, warm-ups, incomplete, bodyweight, edits and deletes, unit switching), exercise history, previous-session pairing, workout summaries, Heart Rate Measurement parsing (8/16-bit, contact, energy, RR, truncated packets, slices), battery, statistics, gaps, chart thinning, zones, the Health payload window, sync identifiers and recovery times.
- **Bluetooth and HealthKit services:** `HeartRateMonitor` and `HealthKitExporter` were type-checked with the same compiler settings against stand-in `CoreBluetooth` and `HealthKit` modules that mirror the API signatures and `Sendable` annotations Apple documents. That found a real Swift 6 data-race error, which is fixed. Both now also compile against the iOS SDK in CI, with the same settings.
- **iOS build and XCTest:** GitHub Actions ([ios.yml](../.github/workflows/ios.yml)) checks that the committed project matches the generator, builds for the simulator and for devices (unsigned) with Xcode 26.6 on macOS 26, and tests on an iPhone 17 Pro simulator running iOS 26.5. [Run 5](https://github.com/gtfol/vitals/actions/runs/36198484916) passed: 39 unit tests (27 core, 7 SwiftData persistence, 5 coordinator) and the UI workflow test.
- **UI workflow:** `WorkoutFlowUITests` starts a strength workout, adds bench press and squat by searching, types loads and reps, and completes sets. It checks that completing a set starts rest, that the rest clock sits above the tab bar rather than under it, and that a new set copies the one before it. Then it finishes, opens the workout from history, switches to kg in settings, and finds the same bench set converted (61.23 × 5) in exercise history. A screenshot of each of those eight screens is kept in the run's `screenshots` artifact. Screenshots are best effort. In [run 7](https://github.com/gtfol/vitals/actions/runs/36199483971), the simulator timed out taking one while vitals was idle, and that failed the test. Now a missed screenshot is recorded as an expected failure and the flow carries on.

The persistence and coordinator tests use an on-disk SwiftData store and a fake exporter. The UI test uses a throwaway store, no Bluetooth, and Apple Health reported as unavailable. None of it exercises a strap, Bluetooth, background execution or real HealthKit writes. Everything ran on iOS 26.5. vitals is built for iOS 17, but it hasn't run on iOS 17 or 18 yet.

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
- [ ] State restoration: with a workout running, let iOS terminate vitals in the background (not a force-quit) and note whether iOS relaunches it for strap data. Record the result; iOS doesn't guarantee it.
- [ ] Heart Rate Push off: status says no heart rate and points to Zepp.

Apple Health
- [ ] With access allowed, finish a workout: exactly one workout with the right type, start and end, and the received heart-rate samples appears in the Health app.
- [ ] Force a failure (for example, finish while access is off, then turn it on) and retry: still exactly one workout. Retry again from history: nothing new is written.
- [ ] A workout with no heart-rate samples saves as a workout; a strength session with no completed sets saves as a heart-rate workout.

Relaunch
- [ ] Force-quit during a workout and reopen: the prompt offers continue or finish, the sets and start time are intact, finishing uses the last known activity time, and no second workout exists. The chart shows the closed period as a gap.

Accessibility
- [ ] VoiceOver through the set table, rest clock and heart-rate strip; the largest Dynamic Type size; a smaller iPhone.

Record results and dates here as they're checked, including any iOS limitation observed.
