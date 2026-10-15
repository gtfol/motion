# Direct Helio sleep sync

Motion reads the Helio Strap's stored history over Bluetooth. Zepp's cloud API and
Apple Health are not in this path. The single Sleep view prefers Helio data, with
optional Apple Health access filling missing nights or metrics.

## Setup

1. Open Settings → **strap** → **connect strap** (or **sleep sync** for an already selected Helio).
2. Choose the same Helio Strap already paired with Zepp. Do not reset or unpair it.
3. Retrieve its existing 32-hex-character authentication key using the
   [Gadgetbridge pairing guide](https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/).
   This may need a computer and a one-time Zepp login. Motion does not collect the
   Zepp login or add an ongoing Zepp account integration.
4. Paste the key into Motion's secure field, close Zepp, keep the band nearby,
   and choose **save & sync**. Never paste the key into issues, chat or logs.
5. Open Motion to sync, or pull down in Sleep to retry. Foreground automatic attempts
   are throttled to fifteen minutes; manual retries are immediate.

Optional fallback: in Settings → Apple Health, choose **connect sleep data**.
No source picker is needed. A Helio sleep record wins for its wake date; otherwise
Motion selects one Health recording, preferring stages and then sleep coverage.
Overlapping recordings, including duplicates assigned to neighboring dates, are not
added together. Stages from different recorders are never spliced into one night.
For each night's heart rate and breathing rate separately, Helio wins if it has
usable asleep readings; otherwise Health supplies that metric. Health readings can
fill a Helio night even when Health has no sleep-stage record. Each metric keeps
one recorder's trace, preferring the selected Health sleep recorder when available.
Missing readings remain blank. Pull-to-refresh reloads both available sources.

The key is scoped to the Motion account and strap, stored using
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and never displayed again.
Remove it from strap setup to stop automatic direct sync. Account deletion removes
that account's band keys and local history. Signing out preserves its isolated copy.

## Data and connection

- The existing heart-rate monitor owns one `CBCentralManager` and one connection.
  Sleep uses the same selected peripheral; standard live heart-rate notifications
  still flow to the workout. There is no second BLE manager competing for the band.
- The first fetch requests seven days of sleep sessions (`0x48`), per-minute
  activity heart rate (`0x01`) and respiratory readings (`0x38`). Later fetches
  overlap the saved cursor to pick up amended nights and deduplicate readings.
- Verified sleep records and readings are retained for ninety days under the current
  account and strap. Files are protected and excluded from backups. They are not
  uploaded through workout sync or written back to Apple Health.
- CRC, lengths, packet order, plausible dates and sleep-stage intervals are checked.
  Bad transfers leave previous saved data and cursors intact. Interrupted transfers
  may retain earlier complete, verified rounds. Unknown stages stay gaps.
- Every fetch acknowledgement uses **keep on device** (`03 09`), including failures.
  Motion never sends the delete acknowledgement (`03 01`), sets the band clock,
  or changes sleep/heart-rate recording settings. Existing band settings determine
  which records are available.
- A five-minute overall deadline and shorter idle deadlines bound a sync. Bad keys
  stop automatic retries until replaced. Missing or refused record types are shown
  as unavailable, not converted to zero or estimated from other signals.
- iOS background execution and concurrent connections held by Zepp vary. Automatic
  overnight background syncing is not promised; opening Motion starts a due sync.

## Protocol provenance

`Packages/HelioProtocol` is a local subset of OpenCircuit's MIT-licensed ZeppKit at
[`2d07e550fbabba61990024e254f8b9654d50bd0a`](https://github.com/perezjuanj/OpenCircuit/tree/2d07e550fbabba61990024e254f8b9654d50bd0a),
before its license change. No later noncommercial source is used. The MIT notice
is included with the package and app bundle; the B-163 implementation retains its
public-domain tiny-ECDH-c attribution. Fake devices and synthetic credentials are
test-only. The package's protocol tests include independent crypto vectors and
failure-path acknowledgement checks.

## Hardware validation still required

Simulator tests establish the integration behavior, not real firmware compatibility.
Before a public release, verify the following with the user's band key entered on
their device:

- [ ] Sync last night's data with Zepp closed and Health permission denied.
- [ ] Compare wake date, bedtime, stage boundaries, awake time, heart rate and breathing
  samples against the same recorded night in Zepp. The upstream protocol's sleep
  minute-reference formula is inferred; verify timestamps, including time-zone/DST
  transitions, against a real capture before claiming accuracy.
- [ ] Reopen and repeat sync: no duplicates; an amended night replaces its earlier version.
- [ ] Check a workout's live heart-rate stream during a sleep fetch.
- [ ] Move out of range, turn Bluetooth off/on, lock/unlock, then retry without data loss.
- [ ] Verify a wrong key fails clearly and a corrected key succeeds.
- [ ] Confirm Zepp can still read all band history after Motion syncs.
- [ ] Verify account switching, key removal and account deletion on device.

No sleep scores, hypopnea estimates or breath-by-breath waveforms are synthesized.
