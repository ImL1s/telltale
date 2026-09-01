# Powertrain battery profiles

Telltale bundles a searchable, integrity-checked catalog of vehicle-specific
powertrain-battery research. The catalog is deliberately broader than the set
of profiles that may send an experimental query, and broader still than the
set that can be installed. A vehicle appearing in search means that Telltale
can show a traceable source and its known gaps; it does **not** mean that
Telltale supports that vehicle or has verified its battery-management system
(BMS).

## Current catalog snapshot

The bundled **schema v3** snapshot contains **221 source-backed profiles**:

| Powertrain | Profiles | Research-only | Experimental | Installable (community) |
| --- | ---: | ---: | ---: | ---: |
| BEV | 89 | 75 | 2 | 12 |
| FCEV | 5 | 5 | 0 | 0 |
| HEV | 48 | 46 | 2 | 0 |
| MHEV | 7 | 7 | 0 | 0 |
| PHEV | 69 | 69 | 0 | 0 |
| REEV | 3 | 3 | 0 | 0 |
| **Total** | **221** | **205** | **4** | **12** |

The **205 `researchOnly` profiles are metadata indexes with no commands**.
They cover identity and discovery evidence but cannot query a vehicle.

The **12 `community` profiles are installable**: MG ZS EV Mk1, MG4 Electric,
MG5 EV (2020–2023), BYD Atto 3 (pre-2024.10 firmware), Hyundai
Ioniq 5 and Ioniq 6 (E-GMP), Kia EV6 (E-GMP), Hyundai Kona Electric (OS),
Kia Niro EV / e-Niro (DE), Kia Soul EV (SK3, 2020 attested year), Renault
Zoe Ph1, and VW e-up! gen2. Community is the cross-corroborated tier —
every installed byte window and formula agrees across at least two mutually
independent, license-pinned implementations, and the runtime still requires
a per-connection vehicle confirmation before a single request is sent.

The **4 `experimental` profiles** (Lexus RX450hL 2020 source vehicle, Toyota
Prius TNGA, Kia EV9, Toyota bZ4X / Subaru Solterra e-TNGA first gen) carry
pinned read-only commands usable only through the
opt-in one-shot laboratory. Experimental commands cannot be installed,
enabled for polling, or added to the dashboard. The EV9's only evidence
family is OBDb, whose signalset marks the pack current unsigned even though
its own capture then decodes to an absurd 6540 A; the entry ships the
physically coherent signed decode and records the upstream disagreement.

The 2026-09 review also recorded **transport-level exclusions** directly on
the affected research entries: BMW i3 and MINI Cooper SE F56 (every SME poll
needs ISO 15765-2 extended addressing), VW ID.3/ID.4 (BMS answers only
through the 29-bit gateway pair), Nissan Ariya (29-bit ISO-TP plus custom
flow control), and Renault Zoe Ph2 (29-bit-only DID set) — in those cases
the data is well corroborated and the transport is the blocker. Fiat 500e
Type 332 stays research-only because no qualifying open DID map exists
(its SGW blocks writes, not reads). Genesis GV60 and
Electrified GV70 stay research-only because their single WiCAN source
attests no model year, and Hyundai Casper/Inster has no usable source at
all. Toyota bZ4X/Solterra community is blocked by a 7D2 vs 747 header
split; the capture-verified 7D2 subset ships as experimental
`toyota-etnga-bev-2022-2024`.

## Status and evidence are separate

`status` controls what the app may do:

| Status | Meaning |
| --- | --- |
| `ready` | Reserved for a profile that completed the project's installable acceptance process with a physical-vehicle run. The current snapshot contains none. |
| `community` | A source-backed read-only mapping whose every formula and byte window is confirmed by at least one source independent of the primary, with pinned artifact hashes. Installable after an install-time identity acknowledgement and a fresh per-connection vehicle confirmation; also eligible for one-shot lab reads. The current snapshot contains twelve. |
| `experimental` | A pinned, bounded candidate eligible only for the opt-in one-shot laboratory. It cannot be installed, polled, persisted as telemetry, or shown on the dashboard. The current snapshot contains four. |
| `researchOnly` | A source or identity index with no executable commands. It cannot be installed or query a vehicle. The current snapshot contains 205. |

`evidence` records where an entry's evidence came from; it never overrides the
status gate:

| Evidence | Meaning |
| --- | --- |
| `sourceBacked` | An external or official source supports the recorded identity or mapping. This is not evidence produced by Telltale on a physical vehicle. |
| `syntheticRig` | A project-owned deterministic simulator exercised the mapping or transport path. This does not establish real ECU or BMS behaviour. |
| `physicalVehicle` | A retained physical-vehicle run supports the stated scope. It still applies only to the recorded market, generation, variant, adapter, ECU software, and test conditions. |

All 221 current entries are `sourceBacked`. Running a synthetic ELM327 rig
through a phone can validate the app, parser, UI, and transport path, but it
does not turn a profile into `physicalVehicle` evidence and does not prove a
real PID or formula.

## The community tier: cross-corroboration instead of trust

A single hobbyist CSV that nobody else agrees with stays experimental no
matter how plausible it looks. Promotion to `community` requires all of:

- at least one corroborating source that is **mutually independent** of the
  primary (not the same author, not derived from the primary), pinned to a
  full commit hash with an explicit redistribution-compatible license;
- agreement on **both the formula and the byte positions** of every shipped
  signal between the sources counted as its corroboration. Where the counted
  sources disagree, the signal is **excluded, not averaged** — the E-GMP
  battery inlet temperature and the MG range DID are recorded exclusions.
  Where one source disagrees but two others still agree in full, that source
  simply stops counting as corroboration for that signal and the
  disagreement is recorded: the Kona-family pack current ships on OVMS and
  OBDb positions with OVMS signedness, with WiCAN's inverted sign noted and
  not counted;
- a pinned SHA-256 of the exact primary source artifact;
- exact market, year and model identity evidence; the variant may be
  generation-scoped (`sourcePartial`) because a BMS wire contract is a
  property of the battery system, which is shared across trims within a
  generation.

Where real response captures exist (the Hyundai/Kia profiles), the shipped
contracts were additionally verified to decode those captures to physically
plausible values before inclusion.

## Installation and the per-connection gate

Installation is deliberately split from trust in the vehicle at the other end
of the adapter:

1. In the catalog, the driver picks a community profile, confirms the exact
   model year and acknowledges the identity scope. This installs read-only
   PID definitions into the PID manager — nothing more.
2. Installed definitions persist only as `{profile_id, vehicle_year}`
   references. On every app start they are rebuilt from the SHA-256-verified
   catalog, so mutable storage can never smuggle a modified formula past the
   integrity check, and a catalog that later withdraws a profile uninstalls
   it cleanly.
3. On every connection, the dashboard asks the driver to confirm that the
   connected vehicle is that exact vehicle. The grant binds the connection
   generation, the vehicle year and the source revision, lives only in
   memory, and dies at every vehicle boundary — plugging into a different
   car never inherits it.
4. Only then does the polling engine transmit the profile's commands, and it
   accepts a reply only from the pinned responder, with the exact declared
   payload length, sliced to each signal's byte window, decoded by the
   reviewed formula, inside the source-bounded range. Anything else is a
   visible fault, never a number.

## Experimental one-shot laboratory

The laboratory is unchanged in spirit: opt-in in Settings, one pinned
Mode 21/22 read per consent, two-minute expiry, five-second cooldown, at most
three attempts per command per connection, quarantine on structural failure,
and nothing persisted into telemetry. Community profiles are also
probe-eligible — a consented single read is strictly less exposure than the
polling they already qualify for, and it lets a driver try one value before
installing.

## Exact response contract

A candidate is eligible for installation or the one-shot laboratory only when
the schema and validator accept its pinned wire contract. The runtime then
requires all of the following before showing a decoded value:

- the profile and command still exist in the verified catalog snapshot;
- the resolved CAN bus width accepts the exact request and response identifiers;
- response headers are present and the reply reassembles to exactly one
  complete response from the pinned responder;
- the positive-response service and identifier echo the request;
- the payload length equals the profile's exact length;
- every signal byte window is inside that payload; and
- every formula returns a finite value inside the source-bounded range.

An anonymous, wrong-responder, ambiguous, wrong-envelope, wrong-length,
formula-error, or out-of-range response is rejected. Session control,
security access, writes, actuator commands, guessed commands, scans, passive
CAN, and TP2.0 are outside this mechanism. An unavailable value is safer than
a plausible but unattributed one.

## Source-specific evidence limits

### MG ZS EV Mk1 — community

Primary: the pinned
[`MG ZS EV.csv`](https://github.com/peternixon/MG-EV-OBD-PID/blob/2f485fcbffa2259d9e1db92d14483c1bef55dcca/extendedpids/MG%20ZS%20EV.csv)
(one Australian 2021 source vehicle). Corroboration: the OVMS `vehicle_mgev`
component independently implements byte-identical decodes for every shipped
DID and pins the Mk1 BMS addressing (781/789), and WiCAN confirms the
SoC/SoH/voltage scales. The mapping is DID-invariant across the SAIC MG EV
BMS family but **addressing-pinned to Mk1 (2019–2021)** — the 2022+ facelift
moved its BMS to 7E5/7ED and is not covered. Range DID B0CE is excluded
(OVMS ships its decode disabled), and the temperature DIDs carry a recorded
MG5 disagreement.

### MG4 Electric — community

Primary: OVMS `vehicle_mg4` at the catalog pin, polling the BMS
functionally at 7DF with responder 7ED. Corroboration: OBDb/MG-MG4 on the
same headers and DID formulas (bus V, pack V, pack A, pack temp, coolant
temp, SoH). This is not the Mk1 ZS EV 781/789 map. Mode 01 PID 5B and DID
B046 are excluded (OVMS MG4 does not poll B046). Temperature floor is
−40 °C from OVMS, not the ZS EV CSV's 0 °C floor.

### MG5 EV (2020–2023) — community

Primary: OVMS `vehicle_mg5`, physical 7E5/7ED. Corroboration: WiCAN
`mg5-marvel-zs.json` for pack voltage, SoH and pack temperature only.
Identity is the OVMS MG5 2020–2023 vehicle type, not WiCAN's
MG5/Marvel/ZS union label. B046 is excluded (`*1.035` vs `/10`); current,
bus voltage and coolant have no second agreeing family.

### BYD Atto 3 (pre-2024.10) — community

Primary: OVMS `vehicle_byd_atto3` on 7E7/7EF, little-endian 0005/0008/0009
and 0032 temperature. Corroboration: WiCAN `byd_202410_update.json` for the
three little-endian live readings (firmware-bound: before the 2024.10
update) and sibling `atto3.json` for 0032 only. The short `atto3.json`
220008 `[B4:B5]` window is not treated as big-endian voltage. DID 1FFC is
excluded. OVMS development vehicle is Australian RHD; the catalog records
Global because neither counted source restricts a type-market.

### Hyundai / Kia BMS family — community

Six profiles share the 7E4/7EC `220101`/`220105` contract with exact 59- and
43-byte payloads: Ioniq 5, Ioniq 6 and EV6 (E-GMP), Kona Electric (OS),
Niro EV (DE), and Soul EV (SK3, attested 2020). Corroborated across OVMS,
WiCAN, OBDb and — for the Soul — SoulEVSpy, whose explicit two's-complement
parser independently confirms the family's signed pack current. The Ioniq 5,
Ioniq 6, EV6 and Kona contracts additionally decode pinned real-vehicle
response captures to the independently-agreed values — the Ioniq 5 capture
is wired through the full production path as a repo test
(`powertrain_capture_regression_test.dart`), and the same capture replays
identically through the separate Ioniq 6 entry
(`powertrain_wave2_wire_contract_test.dart`). The Soul entry excludes the
three battery temperatures: its model-explicit sources decode them unsigned,
so the signed semantics sub-zero readings depend on has no second source.
No Niro-specific raw capture exists at the pinned revisions: its exact
payload lengths are inherited from the byte-identical Kona OS layout, and
its entry says so. Recorded exclusions: E-GMP battery inlet
temperature (decode conflict), E-GMP cell deterioration (decodes to
non-physical values), bit-packed status flags and operating time (numeric
gauges only), and the WiCAN Kona-family current-sign inversion (the shipped
sign follows OVMS/OBDb: positive discharging, negative charging). Responses
are multi-frame ISO 15765-2; an adapter that mishandles flow control times
out rather than corrupting values. Hyundai Ioniq Electric was researched but
ships nothing — no licensed source provides exact payload-length evidence for
its Mode 21 block.

### Lexus RX450hL — experimental

The executable subset is limited to the pinned
[2020 RX450hL profile](https://github.com/NathanNam/obd2-logger/blob/f93d7a0afb1cfb8aff9681a7db33db46d55804a2/src/profiles/builtin/lexus-rx450hl-2020.json)
and supports one 2020 Lexus RX450hL Premium source vehicle. The 2026-09
cross-source review found **no independent confirmation of its byte
windows** — the Ircama Toyota-hybrid oracle documents different semantics at
the same identifiers — so the profile stays experimental and probe-only.

### Toyota Prius (TNGA) — experimental

Capture-verified candidates from the hybrid control ECU (7D2/7DA Mode 22):
SoC, pack voltage, signed pack current, and block SoC. Every formula decodes
OBDb's pinned real-car captures (Prius MY2022/2024/2025; Corolla Hybrid
confirms 1F5B for 2023–2025), but all licensed evidence is a single
organization, so the entry is experimental until an independent source
appears. The forum-circulated 7E2 Mode 21 tables exist only in unlicensed
sources and are not shipped.

### Toyota bZ4X / Subaru Solterra (e-TNGA) — experimental

Capture-verified SoC (`1F5B`) and block SoC (`106C`) from the hybrid
control ECU at 7D2/7DA, matching the Prius TNGA experimental pattern and
pinned MY2023/2024 OBDb captures. Community is blocked: OBDb polls `1F5B`
on 7D2, while the Kezar family (OVMS `vehicle_toyota_etnga` plus
`etnga-obd`, one family) polls it on Battery ECU 747. Pack voltage/current
`1F9A` is not shipped for the same header split. Year ceiling is 2024
(96-cell, capture-verified); MY2025+ bZ4X lists `1F5B` unsupported. The EPA
stub `toyota-bz4x-us-2023-2025` stays identity-only.

### Nissan Leaf and Mitsubishi Outlander PHEV — researched, not shipped

Both have corroborated read contracts in licensed sources, but every source
drives them with custom ELM327 flow control (`ATFCSM1`) and raw app-side
ISO-TP reassembly, which Telltale does not implement. Their entries record
this; nothing is shipped rather than shipped broken.

### Chevrolet Bolt — metadata only

Unchanged: the pinned `iternio/ev-obd-pids` Bolt material remains a discovery
entry only; the provenance chain and responder proof do not pass the
executable gates.

## Promotion path

`researchOnly` → `experimental` requires a pinned wire contract with exact
identity scope and a pinned artifact hash. `experimental` → `community`
requires independent cross-source corroboration of every shipped signal.
`community` → `ready` still requires a separately retained, privacy-reviewed
physical-vehicle run for the exact identity, independent confirmation of
request and responder attribution, exact raw payload shape, formula semantics
and sign, stable ranges, adapter/transport conditions, and source licensing
suitable for redistribution. One plausible value is not acceptance evidence.

## Provenance and licensing

The bundled catalog and manifest record schema version, SHA-256, byte size,
profile count, signal count, and powertrain counts —
`tool/update_powertrain_battery_manifest.py` regenerates the manifest and
`--check` detects drift. Every profile retains a source name, URL, immutable
revision or content hash, licence, path, locator, applicability, and
limitations; executable sources also retain the pinned source-artifact
SHA-256, and community profiles additionally record their corroborating
secondary sources. A catalog integrity, count, or schema failure makes the
whole catalog unavailable rather than loading a partial snapshot.

See [Powertrain battery catalog third-party notices](../THIRD_PARTY_NOTICES_POWERTRAIN_BATTERY.md)
for source-specific attribution, transformation notes, reuse terms, and the
non-endorsement boundary.

## Verification boundary

Unit, parser, widget, integration, phone, and synthetic-rig tests can
establish that the catalog loads, status gates hold, consent expires,
lifecycle boundaries revoke access, requests are framed and attributed,
multi-frame payloads reassemble and slice correctly, and invalid fixtures
fail closed. They do **not** prove:

- that a listed vehicle exposes the same ECU, responder, payload, scale, or
  current sign in every market or model year;
- that a generic ELM327 adapter handles the required timing and framing;
- that state of charge, voltage, current, temperature, torque, range,
  resistance, or health is accurate on a real BMS; or
- that a research-only or experimental vehicle is supported.

Those claims require a separately retained, privacy-reviewed physical-vehicle
run for the exact vehicle and test configuration. No phone or synthetic-rig
transport result substitutes for that real-vehicle PID evidence.
