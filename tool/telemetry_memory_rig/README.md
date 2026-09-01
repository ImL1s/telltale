# Telemetry Android memory rig

Runs an isolated physical-Android process and samples `dumpsys meminfo` every
400 ms. The PSS lane has one measured Flutter invocation:

1. Pinned host Dart generates the 100 MiB index fixture and near-25 MiB
   canonical session with the production telemetry codec. The archive byte
   count and SHA-256 are recorded before any app process starts.
2. The measured app starts from Flutter's newly installed package, emits an
   import-ready handshake, and blocks before baseline until the host streams the
   archive back through `run-as`. The measurement process never generates the
   fixtures. Every index, replay, direct CSV, export/share, connected-policy,
   baseline, and settled
   operation emits timestamped `BEGIN`/`END` markers. `run.sh` assigns each PSS
   sample to the latest live sub-stage and reports the stage owning the peak.

```bash
cd app
tool/telemetry_memory_rig/run.sh <adb-serial>
```

Telemetry CSV and JSON export use the production `TelemetrySessionActions.export`
path through `AppShareEntryController`, including its off-isolate exporter,
the app share coordinator, and a
measured deterministic platform adapter. Raw transcript, recovered transcript, and PID CSV use the same five-entry
production controller through that root coordinator. The separately named
exact-32-MiB probe tests the coordinator limit because canonical telemetry
sessions are capped below 32 MiB.

The analyzer requires samples plus ordered timestamped markers for every stage.
It retains the hard gates: peak TOTAL PSS delta <=96 MiB and final settled delta
<=48 MiB. It does not request or force garbage collection. `app-files.txt` and
`package-lifetime.txt` are captured with `run-as` during an eight-second window
while the measured package PID is still alive; residue capture failure fails the
rig.

This is attributable phone/process/storage evidence through app-owned export and
coordinator paths. The deterministic platform adapter does not open the Android
chooser, and the fixtures are synthetic. It is **not** evidence of a physical
ELM327 adapter, ECU, vehicle, or chooser-provider cleanup.

## Revision-8 completion boundary

After the PSS lane, the runner is configured to execute the seven Gate C rows in
separate seed/recovery installs with exact debug-rig gates. Instrumentation is
not evidence by itself. Gate C remains open until a fresh device run produces
the complete archive described in
[`GATE_C_BLOCKERS.md`](GATE_C_BLOCKERS.md). Readiness output is not force-stop
proof and must not be relabelled as such.

## Sealed source-tree guard

The macOS runner records native per-file FSEvents, retains every raw flag/event
ID, and verifies the sealed source manifest before and after the run. Dropped,
wrapped, root-changed, unknown, created, removed, renamed, content-modified, or
metadata-modified observations fail closed.

APFS can emit an exact `ItemIsFile | ItemCloned` hint for an unchanged source
file when Gradle copies that file into `app/build`. The guard reconciles only
that exact raw flag set for a regular file selected by the sealed manifest. The
eligible set is exact: manifest-selected local inputs, external package inputs,
Flutter-tool package inputs, and manifest-selected toolchain inputs only. It is
never a root-wide package, pub-cache, Flutter SDK, or toolchain whitelist.

Each eligible logical manifest ID is bound one-to-one to a canonical path and a
descriptor-based sidecar fingerprint covering identity, metadata, content, and
xattrs. Aliases must agree on the manifest digest, and the observed path,
logical IDs, scope, baseline fingerprint, and current fingerprint must all match
that sidecar. Package/toolchain files merely located below a watched root do not qualify.
Ignored/generated build outputs remain excluded (`included=false`) and never
receive clone reconciliation or no-delta eligibility. Unlisted paths inside an
included source scope, new clone destinations, and extra watched toolchain roots
absent from the manifest remain fatal baseline-missing events. The raw and
classified records remain paired and checksum-sealed; any additional flag or
fingerprint delta remains a violation.

This reconciliation proves that the observed path had no persistent delta at
capture time; it does not turn FSEvents into a replayable history and cannot
claim absolute detection of every exotic transient clone-and-restore completed
before callback delivery. The final manifest and all other fail-closed event
classes remain mandatory.

## Android SDK write denial

Every Flutter, Dart, and Gradle process tree in this macOS Gate C runner is
started through `android_sdk_sandbox_exec.sh`. Its deny-default profile permits
writes only to the sealed app/Flutter/pub-cache roots and the runner's isolated
Gradle, user, and temporary roots. The canonical Android SDK root is required
to be disjoint from every write root and is intentionally absent from the
write allow-list.

Before the first Gradle repository load, the runner verifies the exact
Apple-signed `/usr/bin/sandbox-exec`, rejects inherited non-standard file
descriptors, fingerprints the profile/wrapper/probe/Python/cache inputs, and
runs a disposable denial matrix. That matrix covers read access, allowed output
writes, seven mutation classes, a non-destructive write-open against the real
`.knownPackages`, and child/grandchild inheritance. The post attestation must
match the complete prepared fingerprints before the source guard may stop.
There is no unsandboxed fallback.

`sandbox-exec` is a deprecated macOS-local defense-in-depth surface. It does
not replace the whole-SDK FSEvents guard, manifest hard-link checks, component
pre/post manifests, or checksum seal. Absence, signature mismatch, overlap,
probe failure, cache metadata change, or wrapper bypass fails Gate C. A passing
sandbox/guard lane proves only that the observed build process tree left the
sealed SDK unchanged; it is not release, adapter, ECU, vehicle, or all-model
compatibility evidence.
