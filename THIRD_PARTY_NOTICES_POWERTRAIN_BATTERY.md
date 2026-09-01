# Powertrain battery catalog third-party notices

The bundled schema-v3 powertrain battery catalog is a curated index of **221
source-backed profiles**: 205 metadata-only `researchOnly` entries, twelve
cross-corroborated installable `community` entries, and four one-shot
`experimental` entries. The executable subset contains 157 bounded signals.
The current snapshot has no `ready` profile.

Telltale does not claim that any entry is supported. Community entries are
independently corroborated source data, not physical-vehicle validation. A
phone or synthetic-rig run may test the app and transport path, but it does
not constitute physical-vehicle PID, formula, or BMS validation.

## Apache License 2.0 sources

### MG ZS EV Mk1 community subset

- `peternixon/MG-EV-OBD-PID`, pinned at
  `2f485fcbffa2259d9e1db92d14483c1bef55dcca`.
- Source path: `extendedpids/MG ZS EV.csv`.
- Pinned source-artifact SHA-256:
  `f20ee02b2710def73c008fb54f086172a4e3323a751e8392efd1f0e3d9de0923`.

Telltale transforms 9 Mode 22 rows into its formula dialect and 9 bounded
signals. The independently implemented OVMS `vehicle_mgev` component (MIT)
corroborates every shipped DID; the WiCAN vehicle profiles (GPL-3.0)
additionally confirm the SoC, SoH and pack-voltage scales. The weakly
corroborated range DID was dropped. The source identifies an
Australian 2021 source vehicle; the Mk1 2019–2021 scope and the 781/789 BMS
addressing pin come from the OVMS corroboration. Expected responder `789`
remains an ISO 15765 physical-address inference. Installation requires an
identity acknowledgement and a fresh per-connection vehicle confirmation.

### Chevrolet, Nissan and Mitsubishi research boundaries

Nissan Leaf and Mitsubishi Outlander PHEV entries record corroborated read
contracts that require custom ELM327 flow control (`ATFCSM1`) and app-side
raw ISO-TP reassembly, which Telltale does not implement; they therefore
remain research-only.

### Lexus RX450hL experimental subset

- `NathanNam/obd2-logger`, pinned at
  `f93d7a0afb1cfb8aff9681a7db33db46d55804a2`.
- Source path: `src/profiles/builtin/lexus-rx450hl-2020.json`.
- Pinned source-artifact SHA-256:
  `8109db2ef0164a199d08afb2c6cfc2c419801d0a508cbfcaa52e657e0e46d29c`.

Telltale limits the mapping to one documented 2020 Lexus RX450hL Premium source
vehicle. Its market and ECU firmware remain unknown. Four Mode 21 commands
(`61`, `62`, `63`, and `95`) become seven bounded signals. The upstream profile
declares `7E2` to `7EA`, formulas, and ranges, and published artifacts support
the selected byte slices. Full exact payload lengths are conservative Telltale
contracts rather than independent raw-frame proof. RX450h, other trims, model
years 2021–2022, and unresolved PID `98` are excluded. The 2026-09
cross-source review found no independent confirmation of the claimed byte
windows, so the subset is one-shot experimental only and cannot be installed.

### Chevrolet Bolt metadata

- `iternio/ev-obd-pids`, pinned at
  `c45a018b60b3341d2d8bfb22cf0491c4e878165a`.

The Bolt material points to a separate All EV Info mapping. Telltale retains
traceable discovery metadata but no executable Bolt command because the
available provenance/licensing chain, raw response evidence, and exact responder
proof do not pass the executable gates.

### VW and Renault corroboration roles

- `iternio/ev-obd-pids` (same pin as above) additionally corroborates the
  e-up! gen2 pack-voltage scale and the OVMS identity scope. Its dissenting
  e-up! SoC scale (`/2.55` against the installed two-source `/2.5`) and its
  conflicting pack-current formula are recorded on the entry as exclusions
  or dissents, not installed. On the Zoe Ph1 entry it is supporting
  material only, because its published init sequence sits outside
  Telltale's transport safety subset.

The catalog normalizes source formulas where retained, adds exact headers,
payload bounds, status/evidence/identity metadata, and explicit limitations.
These are Telltale modifications; the upstream authors do not endorse them.
Apache-licensed source paths and immutable revisions remain on affected entries.

Apache License 2.0:
<https://www.apache.org/licenses/LICENSE-2.0>

The complete Apache License 2.0 text is packaged at
`assets/licenses/Apache-2.0.txt`. This notice and the packaged Apache-2.0,
MIT (wican-bridge and OVMS) and GPL-3.0 texts are registered with Flutter's
`LicenseRegistry` and are reachable in the app from Settings → Open-source
and data licences.

## MIT sources — Open Vehicle Monitoring System 3

- `openvehicles/Open-Vehicle-Monitoring-System-3`, pinned at
  `587a91d7b46bd7ce6d092e5acb7c2d3b7c5d7740` (MIT, full text packaged at
  `assets/licenses/ovms-MIT.txt`).

OVMS vehicle components corroborate — and for the Ioniq 5, Kona Electric,
Niro EV, e-up! gen2, MG4, MG5 EV and Atto 3 community profiles, provide the
primary decode formulas for — the installed BMS signals (`vehicle_mgev`
including `vehicle_mg4` and `vehicle_mg5`, `vehicle_hyundai_ioniq5`,
`vehicle_kianiroev`, `vehicle_vweup`, `vehicle_byd_atto3`). Per-file
artifact SHA-256 digests are recorded on the affected catalog entries. The
`vehicle_renaultzoe` component is recorded on the Zoe Ph1 entry as supporting
material only: its mapping embeds CanZE's CSV verbatim, so it is not counted
as independent corroboration. Telltale reimplements the decodes in its own
formula dialect; no OVMS code is copied.

## GPL-3.0 sources — WiCAN vehicle profiles

- `meatpiHQ/wican-fw`, pinned at
  `bc3ae6d4ad09f32b96ca101b31950e4fbf56b825` (GPL-3.0, full text packaged at
  `assets/licenses/GPL-3.0.txt`).

WiCAN vehicle-profile JSON corroborates DID positions and scales for the MG
(ZS EV Mk1, MG5 EV), Hyundai/Kia, VW e-up! gen2, Renault Zoe Ph1 and BYD
Atto 3 (pre-2024.10) community profiles. The
adapted data (byte windows and scales, re-expressed in Telltale's formula
dialect) is attributed here and on each entry; Telltale's app code is
GPL-3.0 so redistribution terms are compatible.

## Apache-2.0 sources — SoulEVSpy

- `langemand/SoulEVSpy`, pinned at
  `0a1cafb93a65d17e0c7e1bb3ad2bc9cb965d02a7` (Apache-2.0, full text packaged at
  `assets/licenses/Apache-2.0.txt`); decode source `app/src/main/java/com/evranger/soulevspy/util/BMS2019Parser.java`.

SoulEVSpy's `BMS2019Parser` provides the primary decode positions for the
Kia Soul EV (SK3) community profile and independently confirms the
Kona-family signed pack-current convention through its explicit
two's-complement handling. Telltale re-expresses the byte windows and scales
in its own formula dialect; no SoulEVSpy code is copied.

## GPL-3.0 sources — CanZE

- `fesch/CanZE`, pinned at
  `e9554a6081187b034ff79d032e2eaeb94c1206b1` (GPL-3.0-or-later, full text
  packaged at `assets/licenses/GPL-3.0.txt`).

CanZE's Renault-DDT-derived field tables (`ZOE/_Fields.csv`,
`ZOE/_FieldsAlt.csv`) provide the primary decode formulas for the Renault
Zoe Ph1 community profile's EVC signals. Telltale re-expresses the byte
windows and scales in its own formula dialect; no CanZE code is copied.

## OBDb data — CC BY-SA 4.0

Research-index metadata — and, for the community and Toyota experimental
profiles (Prius TNGA, e-TNGA BEV, and MG4 corroboration), executable signal
positions and scales — are adapted from
individually pinned repositories in the
[OBDb organization](https://github.com/OBDb). Each affected entry records the
repository, full commit SHA, source path, and locator; executable entries
also pin the source-artifact SHA-256. The adapted catalog data is distributed
under CC BY-SA 4.0, which Creative Commons has declared one-way compatible
with GPL-3.0, the licence of this application. Telltale adds its own
non-support and protocol-safety limitations.

CC BY-SA 4.0:
<https://creativecommons.org/licenses/by-sa/4.0/>

### Toyota Prius TNGA experimental subset

- `OBDb/Toyota-Prius`, pinned at `0a8c4ec72be860861548a3aeb2be007eecd83941`;
  signalset artifact SHA-256
  `e037a50ab2f256e5f2668aefc63c1ddb30b7686c372be199b3421972b933bd4b`.

Three Mode 22 commands (`1F5B`, `1F9A`, `106C` on `7D2`/`7DA`) become five
bounded signals, verified against the repository's pinned real-car captures.
All licensed evidence is one organization, so the subset is one-shot
experimental only and cannot be installed.

### Toyota bZ4X / Subaru Solterra e-TNGA experimental subset

- `OBDb/Toyota-bZ4X`, pinned at `fad9ece2987eeccc5c0027921aadb7c8cc72a9aa`;
  signalset artifact SHA-256
  `11e8b5957fe6ec9643f6d9afb62494e135aebb9a8c6e737c0ccd873d34b2cfdb`.

Two Mode 22 commands (`1F5B`, `106C` on `7D2`/`7DA`) become three bounded
signals, verified against the repository's pinned MY2023/2024 real-car
captures. A second family (Kezar) agrees the `1F5B` formula but polls a
different header, so the subset stays one-shot experimental and cannot be
installed. `1F9A` is not shipped.

### MG4 Electric community corroboration

- `OBDb/MG-MG4`, pinned at `271f098e5020ca0be109db68dc277d7bfa962c1e`;
  signalset artifact SHA-256
  `a1e27bcde44001454960ad9959d353e2b876993e2d9263ca0f1556cc0726b10d`.

Corroborates the OVMS `vehicle_mg4` 7DF/7ED Mode 22 map. Telltale
re-expresses the agreed byte windows in its own formula dialect.

## MIT-licensed upstream research

- `AkinYavuz1/wican-bridge`, pinned at
  `aa11ba72ede480bb9c9071b84837eadbd2b7e29a`.

Telltale adds a research-only index entry derived from the upstream README's
2021 IONIQ 5 72 kWh scope and responder table. No bridge code or Mode 22 signal
mapping is copied. The Telltale entry adds explicit warnings about raw WiCAN
SLCAN transport, lost consecutive-frame prefixes, the session-controlled
odometer path, and the difference between SAE PID `015B` remaining-life
semantics and traction-battery state of charge. It has no executable command,
is not installable, and is not presented as Telltale physical-vehicle proof.

MIT License: <https://opensource.org/license/mit>

## U.S. EPA FuelEconomy.gov snapshot

Fuel-cell, plug-in hybrid, hybrid, and mild-hybrid index entries reference the
separately hash-checked bundled U.S. EPA FuelEconomy.gov vehicle snapshot.
Every added entry cites exact make/model rows and EPA identifiers. Those rows
establish searchable U.S. model years and the snapshot's vehicle-type
classification only. For mild hybrids, the exact EPA model string also has to
say `MHEV`; the catalog does not infer mild-hybrid status from a manufacturer or
repository name. The rows do not provide ECU identifiers, CAN responders,
transport requirements, signal layouts, fuel-cell stack commands, or
traction-battery equations. U.S. federal government data is identified in the
catalog as public-domain source material.

Telltale's change is limited to normalizing those identity rows into
non-installable, non-executable research profiles with explicit diagnostic
limitations. No EPA entry contributes a vehicle command.

## Safety and support boundary

- The Settings opt-in only reveals the experimental laboratory. Every command
  still needs fresh, one-use, short-lived consent for the current connection,
  profile, source revision, catalog hash, selected year, and fixed command.
- The laboratory can send one pinned Mode 21 or Mode 22 read only. It cannot
  scan, batch, automatically retry, install, schedule polling, persist a decoded
  telemetry value, or publish one to the dashboard.
- Response acceptance requires an exact responder, positive-response echo,
  payload length, signal byte window, finite formula result, and bounded range.
- Session control, writes, security access, actuator commands, passive CAN,
  TP2.0, unsupported bus widths, and guessed responders or identifiers stay
  closed.
- Community entries become installable only after every validator gate
  passes: independent cross-source corroboration, pinned artifact hashes,
  exact identity evidence, and an install-time plus per-connection driver
  confirmation. `ready` additionally requires real-vehicle evidence and
  remains empty.
- Vehicle year, market, make, model, variant, and powertrain metadata are
  applicability gates, not compatibility promises.
- Real vehicle behavior still depends on vehicle generation, market, adapter,
  ECU software, addressing, timing, and transport quality. Synthetic rigs and
  physical phones do not prove real-vehicle PIDs or decoding.
