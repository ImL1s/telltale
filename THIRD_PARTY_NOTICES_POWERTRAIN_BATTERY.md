# Powertrain battery catalog third-party notices

The bundled schema-v2 powertrain battery catalog is a curated index of **205
source-backed profiles**: 203 metadata-only `researchOnly` entries and two
one-shot `experimental` entries. The experimental subset contains 15 fixed
read-only commands and 20 bounded signals. The current snapshot has no `ready`
or `community` profile and **nothing is installable**.

Telltale does not claim that a research-only or experimental entry is supported.
A phone or synthetic-rig run may test the app and transport path, but it does not
constitute physical-vehicle PID, formula, or BMS validation.

## Apache License 2.0 sources

### MG ZS EV experimental subset

- `peternixon/MG-EV-OBD-PID`, pinned at
  `2f485fcbffa2259d9e1db92d14483c1bef55dcca`.
- Source path: `extendedpids/MG ZS EV.csv`.
- Pinned source-artifact SHA-256:
  `f20ee02b2710def73c008fb54f086172a4e3323a751e8392efd1f0e3d9de0923`.

Telltale transforms 11 Mode 22 rows into its formula dialect and 13 bounded
signals. The source identifies an Australian 2021 source vehicle but not its
trim, battery firmware, or ECU firmware. Request header, identifiers, formulas,
and ranges come from the source CSV. Expected responder `789` is inferred from
request address `781`, and payload lengths are formula-window derivations; the
source does not publish a confirming raw frame capture. These commands are
available only through the opt-in one-shot laboratory and cannot be installed.

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
years 2021–2022, and unresolved PID `98` are excluded. The subset is one-shot
experimental only and cannot be installed.

### Chevrolet Bolt metadata

- `iternio/ev-obd-pids`, pinned at
  `c45a018b60b3341d2d8bfb22cf0491c4e878165a`.

The Bolt material points to a separate All EV Info mapping. Telltale retains
traceable discovery metadata but no executable Bolt command because the
available provenance/licensing chain, raw response evidence, and exact responder
proof do not pass the executable gates.

The catalog normalizes source formulas where retained, adds exact headers,
payload bounds, status/evidence/identity metadata, and explicit limitations.
These are Telltale modifications; the upstream authors do not endorse them.
Apache-licensed source paths and immutable revisions remain on affected entries.

Apache License 2.0:
<https://www.apache.org/licenses/LICENSE-2.0>

The complete Apache License 2.0 text is packaged at
`assets/licenses/Apache-2.0.txt`. This notice, that licence text, and the pinned
MIT text are registered with Flutter's `LicenseRegistry` and are reachable in
the app from Settings → Open-source and data licences.

## OBDb data — CC BY-SA 4.0

Research-index metadata is adapted from individually pinned repositories in
the [OBDb organization](https://github.com/OBDb). Each affected entry records
the repository, full commit SHA, `generations.yaml` path, and generation
locator. The adapted catalog data is distributed under CC BY-SA 4.0; Telltale
adds its own non-support and protocol-safety limitations. These entries contain
no executable commands and cannot be installed or probed.

CC BY-SA 4.0:
<https://creativecommons.org/licenses/by-sa/4.0/>

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
- Only future `ready` or `community` entries can become installable after all
  validator, identity, licensing, and real-vehicle evidence gates pass.
- Vehicle year, market, make, model, variant, and powertrain metadata are
  applicability gates, not compatibility promises.
- Real vehicle behavior still depends on vehicle generation, market, adapter,
  ECU software, addressing, timing, and transport quality. Synthetic rigs and
  physical phones do not prove real-vehicle PIDs or decoding.
