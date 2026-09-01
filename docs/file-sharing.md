# File sharing / 檔案分享

Telltale hands exports to the operating system as files. It does not upload
them to a Telltale server. The selected receiving app or system provider owns
what happens after the platform share sheet accepts the handoff.

Production uses the native app-share lifecycle bridge on macOS and the pinned
`share_plus` bridge on the other supported platforms.

## Shareable sources

| Source | Extension | MIME type | Notes |
| --- | --- | --- | --- |
| Telemetry session CSV | `.csv` | `text/csv` | Full validated event stream with spreadsheet-injection protection |
| Telemetry session JSON | `.json` | `application/json` | Full frozen definitions and events |
| Current raw transcript | `.txt` | `text/plain` | Optional hexadecimal rendering; may include diagnostic identifiers |
| Recovered transcript | `.txt` | `text/plain` | Streamed from the previous app process's retained transcript |
| Custom PID definitions | `.csv` | `text/csv` | User-authored names, equations, headers, and units |

Telemetry CSV/JSON privacy exclusions are documented in
[Telemetry session format](telemetry-session-format.md). Raw transcripts and
custom PID exports have different contents and must be reviewed separately;
they can contain VINs, adapter identity, requests/replies, or user-authored
material.

## Safety admission

Share is admitted synchronously only when the root safety authority says the
app is in the foreground, no recording/finalization owns the artifact gate,
and the connection is either disconnected or stopped with a fresh vehicle
speed at or below 5 km/h. Moving, unknown/stale speed, lifecycle, connection,
or recorder changes revoke the permit during preparation.

All recording, recovery, delete, telemetry export, transcript share, and PID
CSV share operations use one app-wide artifact-operation gate. A second file
operation is refused rather than allowed to race the current owner.

## Crash-safe staging protocol

The app stages each share below its application cache directory in
`telltale-app-shares/`. One share group uses an opaque 32-hex identifier:

| File | Purpose |
| --- | --- |
| `<id>.<csv|json|txt>.share` | Immutable source handed to the platform |
| `<id>.lease.json` | Durable state, byte count, fingerprint, timestamps, and result |
| `<id>.lease.json.tmp` | Atomic ledger-transition candidate |

The write-ahead order is deliberate:

1. complete startup reconstruction before routes admit Share;
2. freeze the current safety permit and acquire the artifact gate;
3. prepare the source lazily;
4. count it when its byte length is not known;
5. write, close, reread, recount, and FNV-fingerprint the staged file;
6. durably transition the ledger from `allocated` to `handedOffLease`; and
7. revalidate safety immediately before invoking the platform bridge.

Only a durable `handedOffLease` means the chooser might have received the
file. An `allocated` group is safe to remove during reconstruction because the
platform call cannot have occurred before that state. After the platform
returns, the ledger records `selected`, `dismissed`, `unavailable`, or
`failed`. `selected` describes the share-sheet result; it does not prove that a
remote service uploaded or retained the file.

If safety changes after the durable handoff but before invocation, the ledger
records a `notInvokedSafetyChanged.*` terminal result. If a stream, descriptor,
ledger handle, cancellation, or cleanup cannot be positively closed, the app
retains ownership and requires a fresh-process reconstruction instead of
unlinking an uncertain live resource.

## Capacity and cleanup

- One source may be at most 32 MiB; exactly 32 MiB is accepted.
- At most two staged sources and 64 MiB total are retained.
- Preparation also requires the source size plus 8 MiB and 8 KiB of reported
  free space.
- A handed-off lease becomes cleanup-eligible after 15 minutes. Its ledger
  also records a 24-hour cleanup due time.

Reconstruction accepts only the exact file grammar above, regular files, valid
ledgers, matching extensions, and matching byte count/fingerprint. Unknown,
corrupt, colliding, symlink, directory, socket, orphan, or mismatched entries
block cleanup rather than being followed or guessed. A valid handed-off group
is removed at the next reconstruction once it is cleanup-eligible. OS eviction
of the ephemeral source is accepted only when a valid handed-off ledger makes
the missing source unambiguous.

The `share_plus`/provider may create its own cache mirror. That mirror is
plugin- or OS-owned, not app-owned, and is observed separately from
`telltale-app-shares/`.

## Verification boundary: Revision-8 Gate C

The telemetry memory rig covers the feasible in-process production paths:
five streaming source types, exact source/ledger byte and fingerprint parity,
32 MiB and staging limits, connected/disconnected policy, contention,
pending/never-result state, clock-only retention, cleanup on the next
opportunity, and separate observation of plugin cache files.

It is **not** the complete force-stop matrix. The current production surface
has no deterministic acknowledged pause between verified source and durable
handoff, or between durable ledger reread and platform invocation. The three
UI entrypoints are not all exported as request-builder/controller seams, and a
real platform bridge necessarily opens an interactive chooser. Consequently:

- readiness markers are not force-stop/reconstruction proof;
- an injected measured platform proves app-owned source and ledger state, not
  real chooser delivery or plugin-mirror cleanup; and
- exact multi-install force-stop cuts remain unverified.

The authoritative blocker list is
[`tool/telemetry_memory_rig/GATE_C_BLOCKERS.md`](../tool/telemetry_memory_rig/GATE_C_BLOCKERS.md).
