# Vehicle catalog notices

These notices apply to the normalized data snapshots in this directory. The
project's GPL licence covers the application source code; it does not purport to
relicense government data, agency names, trademarks, photographs, or other
third-party material.

## U.S. EPA FuelEconomy.gov Find-a-Car snapshot

- Dataset: `www.FuelEconomy.gov`
- Data.gov identifier: `E87A4099-3793-47D7-A687-969577FFE4F4`
- Publisher recorded by Data.gov: U.S. EPA Office of Air and Radiation (OAR) –
  Office of Air Quality Planning and Standards (OAQPS)
- Dataset metadata and access terms:
  <https://catalog.data.gov/dataset/www-fueleconomy-gov>
- EPA Standard Open Data License:
  <https://edg.epa.gov/EPA_Data_License.htm>
- Download page: <https://www.fueleconomy.gov/feg/download.shtml>
- FuelEconomy.gov / ORNL disclaimer:
  <https://www.fueleconomy.gov/feg/ORNL-disclaimer.htm>
- Retrieved: `2026-08-29T15:08:19+00:00`
- Source ZIP SHA-256:
  `66a2948c425c3cf8ad61a184a12296099ef368217d3012b3f7531dcc9c5e2649`
- Normalized CSV SHA-256:
  `6dc8aed9232a88844e18f0160e94eeaa75abc0dcf8a36286e3166797f4933331`

Data.gov identifies this EPA dataset's licence as the EPA Standard Open Data
License. That licence states that, unless otherwise specified, data produced by
the U.S. EPA is in the U.S. public domain and is not subject to domestic
copyright protection under 17 U.S.C. section 105. It provides no warranty for
accuracy or utility and recommends reviewing dataset metadata for limitations.

This project applies that basis only to the normalized vehicle-data rows in
`us_epa_vehicles.csv`. It does not include or claim rights in FuelEconomy.gov
vehicle photographs, logos, trademarks, page copy, or third-party content.

## U.S. NHTSA vPIC make snapshot

- Dataset: NHTSA Product Information Catalog and Vehicle Listing (vPIC)
- API source:
  <https://vpic.nhtsa.dot.gov/api/vehicles/GetAllMakes?format=json>
- NHTSA terms: <https://www.nhtsa.gov/about-nhtsa/terms-use>
- Retrieved: `2026-08-29T15:11:00+00:00`
- Source response SHA-256:
  `6efad9b16d1179ff051c450e9abfecefd77319fa08c71af9c90c9aeafeab668a`
- Normalized CSV SHA-256:
  `58b84c162e2cb3a47a6245c117002e337a2b00eedab074382d8ff762bea9cda5`

NHTSA/DOT states that information presented on its website is considered
public information and may be distributed or copied. This file is a normalized
derivative of the cited vPIC response; it is not represented as a distinct
NHTSA publication or as a complete list of consumer-facing brands.

## No endorsement or warranty

EPA, DOE, ORNL, NHTSA, and DOT do not endorse this project, its authors, or any
vehicle, manufacturer, product, or service shown by the application. The
source data and normalized snapshots are provided as-is. The agencies make no
warranty as to accuracy, completeness, adequacy, non-infringement,
merchantability, fitness for a particular purpose, or usefulness. Consult the
adjacent manifests for exact scope, exclusions, retrieval metadata, and hashes.
