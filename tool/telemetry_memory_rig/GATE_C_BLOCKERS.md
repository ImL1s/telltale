# Revision-8 Gate C execution blocker

The two exact coordinator crash cuts, five-entry production Share controller,
strict integration command/ack target, multi-install runner, and observed-only
real `share_plus` mirror lane are implemented and host-contract tested.

Gate C is **not closed by implementation**. It remains blocked until one fresh,
sequential Samsung run produces every required artifact for `allocated`,
`sourceVerified`, `handedOffBeforePlatform`, `platformInvoked`, `pendingResult`,
`neverResult`, and `realPluginMirror`.

The same run must also finish both native source-tree guards with evidence
schema version 3 and policy `sealed-manifest-pure-item-cloned-v2`, with the
expected sealed manifest and baseline-sidecar identities, zero integrity or
unknown-flag failures, and a final manifest matching the pre-run manifest. The
sidecar must cover every manifest-selected logical ID exactly once, bind aliases
to one unique canonical path and digest, and attest the same identity in guard
readiness and result evidence. Any reconciled APFS clone-source observation must
be an exact `ItemIsFile | ItemCloned` raw event paired one-to-one with its exact
manifest logical IDs, scope, canonical path, and full descriptor-based no-delta
fingerprint record.

Eligibility is limited to exact manifest-selected local, external-package,
Flutter-tool-package, and toolchain files. It is never a root-wide whitelist.
Ignored/generated build outputs remain excluded (`included=false`) and never
receive clone reconciliation or no-delta eligibility. Files merely below an
included package, Flutter, pub-cache, or toolchain source scope remain fatal
baseline-missing events when absent from the manifest; this includes extra
watched toolchain roots and new clone destinations. Any missing or mismatched
sidecar record, additional flag, or fingerprint delta remains fatal.

The run must also prepare and later verify the macOS Android-SDK write sandbox
without fallback. The evidence must bind the exact Apple-signed
`/usr/bin/sandbox-exec`, profile, wrapper, probe, Python executable, canonical
write roots, and complete `.knownPackages` fingerprint. The disposable
preflight must prove allowed output writes plus denied mutation, write-open,
child, and grandchild paths. Every Flutter, Dart, Gradle, and Gradle-descendant
process must inherit that policy; any inherited descriptor, root overlap,
component/cache delta, missing post attestation, or SDK guard event remains
fatal. The sandbox is defense in depth and does not relax the existing
whole-SDK source-tree guard.

Each row must contain its exact ack, live PID/package/UID identity, independent
pre-kill source/ledger parity, confirmed force-stop, post-stop validated staging
archive, separate uninstall/install, fresh-root classification, and immutable
post-recovery hashes. `realPluginMirror` additionally requires one live
`cache/share_plus` regular file with byte-count and SHA-256 parity while the app
ledger is still `handedOffLease/result=pending`.

Readiness output is not force-stop proof. Only the complete, checksum-sealed
device archive can close the gate for a run; host-only tests never substitute
for it. Plugin residue is observed only; the harness never restores or mutates
it. FSEvents flags are hints rather than a replayable history, so a successful
run demonstrates the sealed persistent source state and the observed native
event stream; it does not claim absolute exclusion of every hypothetical
callback-before transient clone-and-restore.
