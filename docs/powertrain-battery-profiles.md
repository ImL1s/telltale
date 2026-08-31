# Powertrain battery profiles

Telltale bundles a searchable, integrity-checked catalog of vehicle-specific
powertrain-battery research. The catalog is deliberately broader than the set
of profiles that may send one experimental query, and broader still than the
set that can be installed. A vehicle appearing in search means that Telltale
can show a traceable source and its known gaps; it does **not** mean that
Telltale supports that vehicle or has verified its battery-management system
(BMS).

## Current catalog snapshot

The bundled **schema v2** snapshot contains **205 source-backed profiles**:

| Powertrain | Profiles | Research-only | Experimental | Installable |
| --- | ---: | ---: | ---: | ---: |
| BEV | 74 | 73 | 1 | 0 |
| FCEV | 5 | 5 | 0 | 0 |
| HEV | 47 | 46 | 1 | 0 |
| MHEV | 7 | 7 | 0 | 0 |
| PHEV | 69 | 69 | 0 | 0 |
| REEV | 3 | 3 | 0 | 0 |
| **Total** | **205** | **203** | **2** | **0** |

The **203 `researchOnly` profiles are metadata indexes with no commands**.
They cover identity and discovery evidence, including all 69 PHEV entries, but
cannot query a vehicle. The two `experimental` profiles contain **15 pinned
read-only commands and 20 bounded signals**:

- MG ZS EV, Australian 2021 source vehicle: 11 Mode 22 commands and 13 signals.
- Lexus RX450hL 2020 Premium source vehicle: 4 Mode 21 commands and 7 signals.

No profile is `ready` or `community`, so **nothing in this snapshot is
installable**. Experimental commands cannot be installed, enabled for polling,
or added to the dashboard.

The breadth includes **119 exact U.S. EPA configurations**, plus pinned
open-source discovery entries. EPA rows establish vehicle identity and
powertrain classification only; they provide no BMS PID, CAN responder, payload,
or formula evidence.

## Status and evidence are separate

`status` controls what the app may do:

| Status | Meaning |
| --- | --- |
| `ready` | Reserved for a profile that completed the project's installable acceptance process. The current snapshot contains none. |
| `community` | Reserved for a source-backed, read-only mapping that passes every installable gate, including exact vehicle identity. The current snapshot contains none. |
| `experimental` | A pinned, bounded candidate eligible only for the opt-in one-shot laboratory. It cannot be installed, polled, persisted as telemetry, or shown on the dashboard. The current snapshot contains two. |
| `researchOnly` | A source or identity index with no executable commands. It cannot be installed or query a vehicle. The current snapshot contains 203. |

`evidence` records where an entry's evidence came from; it never overrides the
status gate:

| Evidence | Meaning |
| --- | --- |
| `sourceBacked` | An external or official source supports the recorded identity or mapping. This is not evidence produced by Telltale on a physical vehicle. |
| `syntheticRig` | A project-owned deterministic simulator exercised the mapping or transport path. This does not establish real ECU or BMS behaviour. |
| `physicalVehicle` | A retained physical-vehicle run supports the stated scope. It still applies only to the recorded market, generation, variant, adapter, ECU software, and test conditions. |

All 205 current entries are `sourceBacked`. Running a synthetic ELM327 rig
through a phone can validate the app, parser, UI, and transport path, but it does
not turn a profile into `physicalVehicle` evidence and does not prove a real PID
or formula.

## Experimental one-shot laboratory

The laboratory is deliberately separate from profile installation and normal
polling.

1. In Settings, the driver enables **Powertrain battery evidence laboratory**
   only after acknowledging the evidence and wire-safety limits. This preference
   persists, but it only reveals the laboratory; it is not vehicle trust or
   command authorization.
2. With a live foreground connection, the driver selects one command from one
   experimental profile. The app never discovers, increments, or scans an
   identifier.
3. For that exact attempt, the driver selects the model year and acknowledges
   the source's known identity, its unresolved identity fields, and that the
   vehicle is safely parked.
4. The app creates a one-use in-memory consent bound to the verified catalog
   SHA-256, source revision, profile, command wire key, selected year, and
   connection generation. Consent expires after **two minutes** and is consumed
   before bytes are sent.
5. The app sends exactly one pinned Mode 21 or Mode 22 request. It does not
   batch, automatically retry, change diagnostic session, request security
   access, write, control an actuator, install a PID, schedule polling, or mix a
   decoded value into telemetry or the dashboard.

Each new attempt requires a fresh acknowledgement. A **five-second cooldown**
applies to the same profile and command, with at most **three attempts per
command per connection**. Only one experimental request may be in flight across
the laboratory. A structural response failure quarantines that profile for the
rest of the connection. Starting another connection, disconnecting, losing the
link, putting the app in the background, or disabling the Settings opt-in
invalidates outstanding consent. A late result after any boundary is discarded.

Transport failure or `NO DATA` publishes no value and triggers no automatic
retry. It does not by itself prove that the profile is wrong; another attempt
still requires fresh consent, the cooldown, and the connection attempt limit.
The normal diagnostic transcript records the exact command, response, catalog
hash, and source revision for evidence and user-controlled export, but the
laboratory does not persist the decoded reading as an installed PID or dashboard
value.

## Exact response contract

A candidate is eligible for the one-shot laboratory only when the schema and
validator accept its pinned wire contract. The runtime then requires all of the
following before showing a decoded value:

- the profile and command still exist in the verified catalog snapshot;
- the resolved CAN bus width accepts the exact request and response identifiers;
- response headers are present and there is exactly one complete response frame;
- the responder equals the pinned responder;
- the positive-response service and identifier echo the request;
- the payload length equals the profile's exact length;
- every signal byte window is inside that payload; and
- every formula returns a finite value inside the source-bounded range.

An anonymous, wrong-responder, ambiguous, wrong-envelope, wrong-length,
formula-error, or out-of-range response is rejected and quarantines the profile
for the current connection. Session control, security access, writes, actuator
commands, guessed commands, scans, passive CAN, and TP2.0 are outside this
mechanism. An unavailable value is safer than a plausible but unattributed one.

## Source-specific evidence limits

### MG ZS EV — Australian 2021 source vehicle

The executable subset is derived from the pinned
[`MG ZS EV.csv`](https://github.com/peternixon/MG-EV-OBD-PID/blob/2f485fcbffa2259d9e1db92d14483c1bef55dcca/extendedpids/MG%20ZS%20EV.csv)
and its [source README](https://github.com/peternixon/MG-EV-OBD-PID/blob/2f485fcbffa2259d9e1db92d14483c1bef55dcca/README.md).
The source reports one Australian 2021 vehicle but does not identify the trim,
battery firmware, or ECU firmware. Request header `781`, Mode 22 identifiers,
formulas, and stated ranges come from the pinned CSV. Expected responder `789`
is Telltale's physical-address inference from `781`, not a published raw-frame
observation. Exact payload lengths are derived from the formula byte windows
because the source publishes no raw capture. The profile therefore remains
experimental and must not be extrapolated to another market, trim, model year,
or firmware.

### Lexus RX450hL — exact 2020 Premium source vehicle

The executable subset is limited to the pinned
[2020 RX450hL profile](https://github.com/NathanNam/obd2-logger/blob/f93d7a0afb1cfb8aff9681a7db33db46d55804a2/src/profiles/builtin/lexus-rx450hl-2020.json),
the project's [source-vehicle evidence note](https://github.com/NathanNam/obd2-logger/blob/f93d7a0afb1cfb8aff9681a7db33db46d55804a2/examples/README.md),
and its [published sample artifact](https://github.com/NathanNam/obd2-logger/blob/f93d7a0afb1cfb8aff9681a7db33db46d55804a2/examples/2026-05-03T07-55-45Z__2z6wg3dj.csv).
They support one **2020 Lexus RX450hL Premium** source vehicle. Its market and
ECU firmware remain unknown. The pinned profile directly declares `7E2` to
`7EA`, Mode 21 identifiers `61`, `62`, `63`, and `95`, formulas, and ranges.
Published artifacts support the selected byte slices; the complete exact
payload length is a conservative Telltale contract rather than independent raw
frame proof. RX450h, other RX450hL trims, model years 2021–2022, and unresolved
PID `98` pack-voltage decoding are excluded.

### Chevrolet Bolt — metadata only

The pinned `iternio/ev-obd-pids` Bolt material remains a discovery entry only.
Its chain points to the separate All EV Info mapping, while the available
licensing/provenance chain, raw response evidence, and exact responder proof are
not sufficient for Telltale's executable gates. Bolt command definitions are
therefore absent from the schema-v2 catalog. A Bolt search result is metadata,
not an available experimental query or support claim.

## Future installation path

A future `ready` or `community` profile must pass a separate installable gate.
Installation would persist PID definitions only; it would not automatically add
them to the dashboard or start polling. The driver would still have to confirm
an exact market, make, model, variant, year, and powertrain match for every live
connection, then explicitly enable the wanted signals. Connecting,
disconnecting, or losing the link invalidates that authorization.

Promotion also requires evidence beyond a successful synthetic response: a
retained and privacy-reviewed physical-vehicle run for the exact identity,
independent confirmation of request and responder attribution, exact raw payload
shape, formula semantics and sign, stable ranges, adapter/transport conditions,
and source licensing suitable for redistribution. One plausible value is not
acceptance evidence.

## Provenance and licensing

The bundled catalog and manifest record schema version, SHA-256, byte size,
profile count, signal count, and powertrain counts. Every profile retains a
source name, URL, immutable revision or content hash, licence, path, locator,
applicability, and limitations. Executable experimental sources also retain the
pinned source-artifact SHA-256. A catalog integrity, count, or schema failure
makes the whole catalog unavailable rather than loading a partial snapshot.

See [Powertrain battery catalog third-party notices](../THIRD_PARTY_NOTICES_POWERTRAIN_BATTERY.md)
for source-specific attribution, transformation notes, reuse terms, and the
non-endorsement boundary.

## Verification boundary

Unit, parser, widget, integration, phone, and synthetic-rig tests can establish
that the catalog loads, status gates remain closed, consent expires, lifecycle
boundaries revoke access, one request is framed, a deterministic response is
attributed, and invalid fixtures fail closed. They do **not** prove:

- that a listed vehicle exposes the same ECU, responder, payload, scale, or
  current sign in every market or model year;
- that a generic ELM327 adapter handles the required timing and framing;
- that state of charge, voltage, current, temperature, torque, range, resistance,
  or health is accurate on a real BMS; or
- that a research-only or experimental vehicle is supported.

Those claims require a separately retained, privacy-reviewed physical-vehicle
run for the exact vehicle and test configuration. No S24U, other phone, or
synthetic-rig transport result substitutes for that real-vehicle PID evidence.
