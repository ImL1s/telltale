# Telemetry session format / 遙測工作階段格式

Telltale stores a recording as a versioned, line-delimited JSON document. The
canonical file is an internal app artifact; CSV and JSON exports are the
supported interchange formats. Do not edit an `.ndjson` file and put it back
into the app's documents directory.

## Files and lifecycle

Canonical artifacts live below the app documents directory in
`telltale-telemetry/`:

| Name | Meaning |
| --- | --- |
| `<32-lowercase-hex>.ndjson.part` | Staging file owned by an active or interrupted recording |
| `<32-lowercase-hex>.ndjson` | Finalized session with a validated footer |

The opaque identifier is both the file-group key and the header `sessionId`.
The writer creates the staging file exclusively, flushes the header before
accepting a recording, appends complete lines, then writes and flushes the
footer before installing the final name.

On startup, recovery validates the staging file before any mutation:

- a positive-value, incomplete session is truncated to its last complete
  validated line, receives one footer with terminal reason
  `recoveredAfterInterruption`, and is installed;
- a complete staging session can be installed unchanged;
- a zero-value staging session is deleted; and
- corrupt or colliding artifacts never become history rows. They remain
  delete-only damaged artifacts.

Recovery rechecks file identity and parsed counters immediately before it
changes a file. An indeterminate mutation requires a fresh app process rather
than continuing with uncertain ownership.

## Envelope

Every line ends in LF (`0x0A`) and contains one JSON object. The order is
strict:

1. exactly one `header` line;
2. zero or more `value` or `status` event lines; and
3. exactly one `footer` line.

The current reader accepts only `schemaVersion: 1`. It rejects invalid UTF-8,
an incomplete tail, an unknown schema or enum, duplicate/misordered envelope
records, unknown PID references, a decreasing elapsed axis, non-finite values,
and footer/count mismatches.

### Header

| Field | Contract |
| --- | --- |
| `schemaVersion` | Integer `1` |
| `sessionId` | 32 lowercase hexadecimal characters |
| `startedAtUtc` | Canonical UTC timestamp |
| `source` | `demo`, `simulatedRig`, or `fieldAppConnection` |
| `transport` | Frozen transport kind used by the session |
| `protocol` | Protocol description captured at Start |
| `signals` | One to 32 frozen signal definitions |
| `configurationFingerprint` | FNV-1a 64 fingerprint of the ordered canonical definitions |

Each signal stores the complete frozen definition (`id`, names, request,
header, unit, unit provenance, range, custom/variant flags, priority, and
equation) plus its own fingerprint. Optional `evidenceKind` and `assumptions`
are omitted when empty so older recordings keep their fingerprints. Derived
horsepower / fuel-rate signals freeze the Start vehicle-parameter disclosure
into `assumptions`. A live definition must match both its exact canonical bytes
and fingerprint. The FNV value is an integrity/equality check, not a
cryptographic signature and not authorization by itself.

Source labels are evidence labels, not compatibility claims:

- `demo` means the built-in Demo transport;
- `simulatedRig` means a non-Demo connection explicitly marked as simulated;
  and
- `fieldAppConnection` means an ordinary app connection. It does not prove the
  adapter, ECU, PID accuracy, or vehicle model independently.

### Events

Both event kinds contain `observedAtUtc`, a nondecreasing monotonic
`elapsedUs`, and `pidId`.

| Type | Additional fields | Meaning |
| --- | --- | --- |
| `value` | `sourceTimestampUtc`, finite numeric `value`, optional `quality` | A fresh value whose frozen PID definition still matches Start |
| `status` | `status` | The signal is unavailable for the named reason |

The status wire values are `stale`, `unsupported`, `noAnswer`, `formulaError`,
`busError`, `headerMismatch`, and `unsafeServiceRefusal`. Repeated identical
status events are suppressed. A `gap` is counted only when a signal that had
an available value becomes unavailable; initial unavailability is not a gap.

`quality` on a value event is omitted when `valid` so existing recordings
round-trip. `outOfReferenceRange` keeps the finite number and labels it 異常;
it is not a reason to drop the sample or to mark the whole file 已驗證.

CSV export version 2 adds `availability`, `origin`, `evidence`, `quality`,
`operation_risk`, `formula`, and `assumptions` columns from the same
USABILITY-R2 policy the live UI uses. Mixed evidence is never upgraded to
`fieldVerified`. Estimate `assumptions` may include vehicle parameters used
for 馬力/油耗 (mass, drag, displacement, fuel). The full vehicle-profile
document, VIN, GPS, account, adapter address, and raw diagnostic traffic
remain excluded; the CSV header records `estimate_assumptions=included`.

`observedAtUtc` is when the recorder inspected the snapshot.
`sourceTimestampUtc` is the timestamp carried by the accepted reading.
`elapsedUs` is the app's monotonic recording clock and is the authoritative
ordering/replay axis; consumers must not treat it as wall-clock time or assume
that it starts at zero.

### Footer

| Field | Contract |
| --- | --- |
| `endedAtUtc` | Canonical UTC timestamp |
| `terminalReason` | Why acceptance stopped |
| `valueCount` | Exact number of value events |
| `statusCount` | Exact number of status events |
| `gapCount` | Exact available-to-unavailable transitions |
| `bytesBeforeFooter` | Exact encoded byte length of header plus events |

The parser recomputes all four counters. A footer is not accepted merely
because its JSON shape is valid.

## Limits and stop reasons

- Maximum signals per session: 32.
- Maximum recording duration: 60 minutes.
- Maximum canonical session group: 25 MiB, including a reserved 2 KiB footer.
- Maximum library: 20 artifact groups and 100 MiB of recognized artifacts.
- Header line limit: 64 KiB; event/footer line limit: 2 KiB.
- Writer and incremental-reader chunks: 64 KiB.

The effective per-session byte limit can be lower when the remaining library
capacity is below 25 MiB. Recording stops fail-closed for duration, session or
library size, storage backpressure, configuration changes, disconnects,
backgrounding, replacement, or storage failure. The exact value appears in
`terminalReason`.

## CSV and JSON exports

Both export paths fully validate the canonical source before emitting bytes,
then validate it again while streaming. A semantic source fingerprint prevents
a changed second pass from being reported as successful.

CSV begins with comment metadata and then these columns:

`observed_at_utc`, `source_timestamp_utc`, `elapsed_ms`, `pid_id`,
`signal_name`, `event_type`, `value`, `unit`, `status`.

Cells beginning with spreadsheet formula characters are prefixed with an
apostrophe. JSON contains `exportVersion`, privacy exclusions, the complete
canonical header, every recorded event, and the footer. Unlike the sampled UI
preview, both exports retain every event that the canonical session accepted.

Neither format includes VIN, GPS, account data, vehicle profiles, adapter
addresses, or raw diagnostic traffic. JSON does include complete frozen PID
definitions, so user-authored labels, units, and equations may still be
personal or proprietary. Review a file before publishing it.

See [File sharing](file-sharing.md) for staging, chooser handoff, retention,
and crash boundaries.
