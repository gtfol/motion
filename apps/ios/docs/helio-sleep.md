# Direct Helio sleep sync

Motion reads the Helio Strap's stored history over Bluetooth. Zepp's cloud API and
Apple Health are not in this path. The single Sleep view prefers Helio data, with
optional Apple Health access filling missing sleep periods or metrics.

Sleep opens in **daily**, with every sleep period ending on the selected date combined
into one total, stage timeline, and heart/breathing chart, including naps. The chart
retains each period's actual times and leaves gaps between periods empty; awake time
and gaps do not count toward the sleep total or asleep averages. **Weekly** uses the
same combined daily totals and averages. Its schedule shows every recorded period
without filling the time between them. There is no separate nap card or nap total.
The weekly arrows move seven days at a time, up to today. Switching views keeps the
selected date; both support pull-to-refresh.
Explicit Helio record boundaries are retained, even when sessions are close together.
Health stage samples have no session IDs; gaps over one hour separate their periods.

## Setup

1. Open Settings → **strap** → **connect strap** (or **strap settings** for an already selected Helio).
2. Choose the same Helio Strap already paired with Zepp. Do not reset or unpair it.
3. Retrieve its existing 32-hex-character authentication key using the
   [Gadgetbridge pairing guide](https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/).
   This may need a computer and a one-time Zepp login. Motion does not collect the
   Zepp login or add an ongoing Zepp account integration.
4. Paste the key into Motion's secure field, close Zepp, keep the band nearby,
   and choose **save key**. In Settings → strap, choose **sync now** next to
   **strap settings**. The key sheet only manages the key; sync progress, errors and
   the last successful sync appear on the main Settings screen. Never paste the key into issues, chat or logs.
5. Open Motion to sync, or pull down in Sleep to retry. Foreground automatic attempts
   are throttled to fifteen minutes; manual retries are immediate.

Optional fallback: in Settings → Apple Health, choose **connect sleep data**.
After answering the permission prompt, the action becomes **manage sleep access**.
If iOS has already asked for all three read types, tapping it opens a short guide
with **open Health** instead of silently repeating the authorization request.
Use Health → profile → Apps → motion to change access. Motion refreshes readable
measurements after the initial request and when returning from Health. An empty
query is not treated as proof that access was denied.
No source picker is needed. A Helio sleep record wins for overlapping sleep periods; otherwise
Motion selects a Health recording, preferring stages and then sleep coverage. A
separate Health nap on the same date can fill a gap without duplicating the main sleep.
Overlapping recordings, including duplicates assigned to neighboring dates, are not
added together. Overlapping stages from different recorders are never spliced; selected nonoverlapping periods share the daily timeline.
For each sleep period's heart rate and breathing rate separately, Helio wins if it has
usable asleep readings; otherwise Health supplies that metric. Health readings can
fill a Helio night even when Health has no sleep-stage record. Each metric keeps
one recorder's trace, preferring the selected Health sleep recorder when available.
Missing readings remain blank. Pull-to-refresh reloads both available sources.

The key is scoped to the Motion account and strap, stored using
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and never displayed again.
Remove it from strap settings to stop automatic direct sync. Account deletion removes
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
  Bad transfers leave previous saved data and cursors intact. Within a verified
  sleep round, each record is validated independently: valid sessions are saved even
  when another record is rejected, while the rejected record's old copy is kept.
  That sleep cursor does not advance, so a later sync can retry it. Unknown stages stay gaps.
  Stage end minutes are inclusive: an equal start/end records one minute, not zero.
  Motion converts them to exclusive boundaries for duration and chart calculations,
  capped at the next stage's start and the session end. Raw minute fields are preserved.
  Shared-boundary records remain nonoverlapping; genuine gaps and unknown stages
  remain blank. Raw endpoints may overhang the declared session by at most one minute;
  these edges are clipped. Larger discrepancies, reversed intervals, duplicate starts
  and overlaps still reject that record. Retried records replace the old local copy;
  existing archives are not blindly extended without rereading the strap.
- A zero-stage sleep record is an expected empty record and does not reject other
  sessions in the same transfer. An overflowing stage table, invalid dates or invalid
  stage intervals reject that record without advancing the sleep cursor.
  Motion then continues with independent heart-rate and breathing downloads. Content
  errors identify the reason separately from failures writing the local archive.
  Sleep shows a compact **sync incomplete** status above the charts. Tap it for a plain-language explanation and retry; diagnostics are never printed below the charts.
  Long-press a sync error in Settings to **copy sync details**. These
  diagnostics contain relative minute offsets only, with no key, packets, absolute
  timestamps, account identity or heart/breathing readings; nothing is uploaded.
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
The October 17 device diagnostic reports start offset +222 minutes, end offset -235
minutes and raw duration zero: a one-minute stage entirely inside the declared session.
This reproduces the rejection exactly and corroborates the inclusive-end observations
in [OpenCircuit issue 312](https://github.com/perezjuanj/OpenCircuit/issues/312).
Synthetic wire tests cover that report, inclusive stage totals, real gaps, combined
sleep/nap records, replay and archive preservation. A completed real-device sync with
the fix and timestamp comparison remain required. Opening Zepp may populate the Health
fallback; that does not verify direct sync.
Before a public release, verify the following with the user's band key entered on
their device:

- [ ] Sync last night's data with Zepp closed and Health permission denied.
- [ ] Compare wake date, bedtime, stage boundaries, awake time, heart rate and breathing
  samples against the same recorded night in Zepp. The upstream protocol's sleep
  minute-reference formula is inferred; verify timestamps, including time-zone/DST
  transitions, against a real capture before claiming accuracy.
- [ ] Compare all sleep periods with Zepp, including a nap before daytime sleep; verify the combined total and empty gap on the timeline.
- [ ] Reopen and repeat sync: no duplicates; an amended night replaces its earlier version.
- [ ] Check a workout's live heart-rate stream during a sleep fetch.
- [ ] Move out of range, turn Bluetooth off/on, lock/unlock, then retry without data loss.
- [ ] Verify a wrong key fails clearly and a corrected key succeeds.
- [ ] Confirm Zepp can still read all band history after Motion syncs.
- [ ] Verify account switching, key removal and account deletion on device.

No sleep scores, hypopnea estimates or breath-by-breath waveforms are synthesized.
