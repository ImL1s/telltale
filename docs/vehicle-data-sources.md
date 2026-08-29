# Vehicle data sources and evidence boundaries

Telltale keeps vehicle identity data offline so normal make/model selection does
not disclose a VIN, a vehicle search, or an app user's browsing pattern to a
third-party service. An offline snapshot also makes the same catalog available
without network access. The snapshot's source, retrieval metadata, hashes, and
coverage statistics are recorded in
`assets/vehicle_catalog/us_epa_vehicles.manifest.json`.
Dataset-specific reuse and no-endorsement notices are recorded in
[`assets/vehicle_catalog/NOTICE.md`](../assets/vehicle_catalog/NOTICE.md).

The repository also keeps a separate NHTSA vPIC make-identity snapshot in
`us_vpic_makes.csv`. It is an audit/discovery source, not a fallback spec table:
the two agencies use different identity concepts and their names are never
joined automatically.

## Bundled catalog: U.S. EPA FuelEconomy.gov

The bundled `us_epa_vehicles.csv` is a normalized subset of the official
[FuelEconomy.gov downloadable vehicle data](https://www.fueleconomy.gov/feg/download.shtml).
FuelEconomy.gov is administered by Oak Ridge National Laboratory for the U.S.
Department of Energy and the U.S. Environmental Protection Agency. Its vehicle
data come from testing by EPA and from manufacturers under EPA oversight.

Coverage is limited to the **1984-through-current U.S. Find-a-Car vehicle
configurations present in the retrieved snapshot**. A snapshot can include a
preliminary next model year. It is not evidence that every brand or configuration
sold worldwide is represented.

The normalized file retains only exact upstream values for:

- EPA vehicle ID, model year, make, model, and base model
- transmission and drive descriptor
- general, primary, and secondary fuel type, plus EPA alternative-vehicle type
- engine displacement and cylinder count
- EPA row modification timestamp

Empty upstream values remain empty. Telltale does not use make-level or
model-level guesses to fill them.

This catalog does **not** provide or imply curb weight, engine torque, drag
coefficient, volumetric efficiency, frontal area, or trim-exact performance
specifications. Those values must remain unknown unless a separate, exact,
traceable source supports the applicable market/year/make/model/configuration.

At the 2026-08-29 snapshot, the normalized catalog has **50,242 exact EPA
configuration rows, 146 EPA `make` labels, and model years 1984–2027**. EPA's
`make` is the manufacturer/division label in this dataset, not a claim that the
snapshot contains 146 complete consumer brands. The app
validates the bundled CSV's SHA-256, byte length, schema, ordered unique EPA
IDs, row count, make count, and year bounds before making it selectable.

The current profile adapter applies only:

- positive engine displacement within the profile's supported range; and
- gasoline or diesel only when the EPA row names one primary fuel, no secondary
  fuel, and an alternative-vehicle type that is either empty or `Diesel`.

Dual-fuel, conventional/plug-in hybrid, electric, hydrogen, CNG, and propane
rows remain browsable exact source records, but no incompatible fuel assumption
is copied. If a record has zero compatible profile fields, it remains
browsable but the picker offers only a close action and does not change the
saved physics profile. The app does not currently persist a separate
catalog-identity selection.
EPA drive layout is displayed for disambiguation only: it is not copied into
the profile because the existing drivetrain field also carries a transmission
efficiency assumption that EPA does not establish.

### Updating and checking

From `app/`:

```bash
python3 tool/update_us_vehicle_catalog.py
python3 tool/update_us_vehicle_catalog.py --check
```

The dependency-free updater uses an explicit User-Agent and timeout, validates
the required upstream schema and row identities, sorts by numeric EPA vehicle
ID, writes UTF-8 CSV with stable line endings, and replaces each output
atomically. `--check` downloads and regenerates the current official snapshot,
then compares the CSV and manifest while ignoring only `retrieved_at_utc`.

## Auditable make identities: U.S. NHTSA vPIC

The repository snapshot `us_vpic_makes.csv` comes only from NHTSA's official
[`GetAllMakes`](https://vpic.nhtsa.dot.gov/api/vehicles/GetAllMakes?format=json)
endpoint. At retrieval on 2026-08-29 it contained **12,351 vPIC make records**.
These entries concern vehicles intended for sale or importation into the United
States; they are not necessarily distinct
consumer-facing brands, do not prove that a model was sold, and carry no
vehicle physics.

Update or reproduce it from `app/`:

```bash
python3 tool/update_us_vpic_makes.py
python3 tool/update_us_vpic_makes.py --check
python3 -m unittest discover -s test/tool -p 'test_update_us_vpic_makes.py'
```

The updater validates the exact vPIC response schema, `Count`, positive unique
make IDs, non-empty unique normalized names, stable ordering, and raw/output
SHA-256 hashes. Its manifest explicitly rejects a global-completeness claim.

## Other official sources and gaps

These sources are complementary. They must not be silently joined by make/model
text alone because market names, model years, trims, engines, and homologation
variants can differ.

### U.S. NHTSA vPIC

[NHTSA's official vPIC API](https://vpic.nhtsa.dot.gov/api/) is based on
manufacturer submissions and supports VIN decoding plus make/model queries.
NHTSA states that vPIC represents vehicles intended for sale or import into the
United States; non-U.S. vehicles may return limited results. VIN decoding can
improve identity evidence, but it does not establish every physical or
performance parameter, and VINs should not be transmitted without a deliberate
user-facing privacy decision. NHTSA also provides
[standalone VIN-decoding databases](https://vpic.nhtsa.dot.gov/downloads/) with
their own size and integration costs.

### Taiwan Ministry of Economic Affairs, Energy Administration

Taiwan's government open-data portal publishes dataset 11163,
[車輛油耗指南](https://data.gov.tw/dataset/11163), from the Ministry of Economic
Affairs Energy Administration. It covers fuel-consumption test results for
approved vehicle models sold in Taiwan, is updated on an irregular schedule,
and uses the Taiwan Government Open Data License 1.0. It is useful for Taiwan
market evidence but is not a global identity catalog and does not guarantee the
physical parameters required for derived power or torque estimates.

### European Environment Agency CO2 monitoring

The EEA publishes official
[CO2 monitoring data for new passenger cars](https://www.eea.europa.eu/en/datahub/datahubitem-view/fa8b1229-3db6-495d-b18e-9c9b3267c02b)
reported under Regulation (EU) 2019/631. It covers new registrations in the
reporting European countries and includes homologation-oriented fields such as
manufacturer, type/variant/version, emissions, mass, engine capacity, and power.
It is annual registration/compliance data, not an all-years global catalog;
reported identifiers and variants require careful market-specific matching.

### Japan Ministry of Land, Infrastructure, Transport and Tourism

Japan's MLIT publishes [current fuel-economy performance tables](https://www.mlit.go.jp/jidosha/jidosha_fr10_000013.html)
and [historical fuel-economy lists](https://www.mlit.go.jp/jidosha/jidosha_mn10_000002.html)
for domestic and imported vehicles in the Japanese new-vehicle publication
scope. The tables can support make/model, transmission, drive, vehicle-mass,
and test-cycle values. They are not yet bundled because the publication is
split across changing PDF/table files; each revision needs a parser,
field-semantic contract, and file-specific reuse-rights check before use. The
repository does not assume that every linked file permits normalization and
redistribution.

### Brazil INMETRO PBE Veicular

INMETRO publishes official [PBE Veicular efficiency tables](https://www.gov.br/inmetro/pt-br/assuntos/regulamentacao/avaliacao-da-conformidade/programa-brasileiro-de-etiquetagem/tabelas-de-eficiencia-energetica/veiculos-automotivos-pbe-veicular)
for participating Brazilian-market light vehicles. The current official page
publishes annual/cycle PDF tables with make, model, version, engine,
transmission, fuel, consumption, CO2, energy efficiency, and electric range,
but not reliable mass, torque, Cd, or VE. The page is marked CC BY-ND 3.0, so
Telltale must not normalize and redistribute those tables as a derived catalog
without separate permission or a file-specific licence that permits it.

### United Kingdom DfT/DVLA licensing data

The UK publishes [vehicle licensing CSV files](https://www.gov.uk/government/statistical-data-sets/vehicle-licensing-statistics-data-files)
under the Open Government Licence. They are useful for aggregate market/make/
model discovery, but records are counts rather than exact configurations and
engine size may be a band. They therefore cannot populate an individual
vehicle profile.

## Acceptance rule

Brand/model identity may be shown only at the specificity supported by its
source. Configuration-specific derived calculations remain disabled when a
required parameter is missing, ambiguous, conflicting, or sourced for a
different market/configuration. "Unknown" is a valid and safer result than an
unverified default.

There is no honest finite acceptance test for "every brand and every vehicle
worldwide": no official source makes that claim, markets use different
homologation identities, and some required physics fields are not published at
all. Completeness is therefore always reported as `source + market + snapshot +
row count + year range`, never as a universal brand-support promise.
