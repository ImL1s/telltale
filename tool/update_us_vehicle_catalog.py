#!/usr/bin/env python3
"""Update the offline U.S. EPA Find-a-Car vehicle identity catalog.

This tool intentionally copies only identity and powertrain descriptors present
in the official FuelEconomy.gov CSV. It does not derive or infer physical
vehicle specifications.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import urllib.request
import zipfile
from datetime import datetime, timezone
from typing import Mapping, Sequence


SOURCE_URL = "https://www.fueleconomy.gov/feg/epadata/vehicles.csv.zip"
SOURCE_PAGE = "https://www.fueleconomy.gov/feg/download.shtml"
USER_AGENT = "TelltaleVehicleCatalogUpdater/1.0 (+https://github.com/ImL1s/telltale)"
DOWNLOAD_TIMEOUT_SECONDS = 120
ARCHIVE_MEMBER = "vehicles.csv"

SCRIPT_DIR = Path(__file__).resolve().parent
APP_DIR = SCRIPT_DIR.parent
DEFAULT_OUTPUT_DIR = APP_DIR / "assets" / "vehicle_catalog"
CATALOG_FILENAME = "us_epa_vehicles.csv"
MANIFEST_FILENAME = "us_epa_vehicles.manifest.json"

SOURCE_COLUMNS = (
    "id",
    "year",
    "make",
    "model",
    "baseModel",
    "trany",
    "drive",
    "fuelType",
    "fuelType1",
    "fuelType2",
    "atvType",
    "displ",
    "cylinders",
    "modifiedOn",
)

OUTPUT_COLUMNS = (
    "epa_id",
    "year",
    "make",
    "model",
    "base_model",
    "transmission",
    "drive",
    "fuel_type",
    "fuel_type_primary",
    "fuel_type_secondary",
    "alternative_vehicle_type",
    "displacement_l",
    "cylinders",
    "modified_on",
)

SOURCE_TO_OUTPUT = dict(zip(SOURCE_COLUMNS, OUTPUT_COLUMNS, strict=True))


class CatalogError(RuntimeError):
    """Raised when the upstream archive cannot be safely normalized."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def download_archive(url: str) -> tuple[bytes, Mapping[str, str]]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/zip, application/octet-stream;q=0.9, */*;q=0.1",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(
            request,
            timeout=DOWNLOAD_TIMEOUT_SECONDS,
        ) as response:
            archive = response.read()
            headers = {key.lower(): value for key, value in response.headers.items()}
    except OSError as error:
        raise CatalogError(f"download failed: {error}") from error

    if not archive:
        raise CatalogError("download returned an empty archive")
    return archive, headers


def read_source_csv(archive: bytes) -> str:
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            members = [item for item in bundle.infolist() if not item.is_dir()]
            if len(members) != 1 or members[0].filename != ARCHIVE_MEMBER:
                names = ", ".join(item.filename for item in members) or "<none>"
                raise CatalogError(
                    f"archive must contain only {ARCHIVE_MEMBER!r}; found {names}"
                )
            if members[0].file_size <= 0:
                raise CatalogError(f"{ARCHIVE_MEMBER} is empty")
            raw_csv = bundle.read(members[0])
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        if isinstance(error, CatalogError):
            raise
        raise CatalogError(f"invalid zip archive: {error}") from error

    try:
        return raw_csv.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise CatalogError(f"{ARCHIVE_MEMBER} is not valid UTF-8: {error}") from error


def normalized_catalog(source_csv: str) -> tuple[bytes, dict[str, int]]:
    reader = csv.DictReader(io.StringIO(source_csv, newline=""))
    if reader.fieldnames is None:
        raise CatalogError("source CSV has no header")

    missing_columns = sorted(set(SOURCE_COLUMNS) - set(reader.fieldnames))
    if missing_columns:
        raise CatalogError(
            "source CSV is missing required columns: " + ", ".join(missing_columns)
        )

    rows: list[tuple[int, dict[str, str]]] = []
    seen_ids: set[int] = set()
    makes: set[str] = set()
    years: list[int] = []

    for source_row_number, row in enumerate(reader, start=2):
        if None in row:
            raise CatalogError(f"source row {source_row_number} has extra columns")

        epa_id_text = row["id"]
        year_text = row["year"]
        try:
            epa_id = int(epa_id_text)
            year = int(year_text)
        except (TypeError, ValueError) as error:
            raise CatalogError(
                f"source row {source_row_number} has invalid id/year: "
                f"{epa_id_text!r}/{year_text!r}"
            ) from error

        if epa_id <= 0:
            raise CatalogError(f"source row {source_row_number} has non-positive id")
        if epa_id in seen_ids:
            raise CatalogError(f"source contains duplicate EPA id {epa_id}")
        if year < 1984:
            raise CatalogError(
                f"source row {source_row_number} has year {year}, below catalog bound 1984"
            )
        if not row["make"] or not row["model"]:
            raise CatalogError(
                f"source row {source_row_number} has an empty make or model"
            )

        output_row: dict[str, str] = {}
        for source_column, output_column in SOURCE_TO_OUTPUT.items():
            value = row[source_column]
            if value is None:
                raise CatalogError(
                    f"source row {source_row_number} has no value for {source_column}"
                )
            if "\x00" in value:
                raise CatalogError(
                    f"source row {source_row_number} contains a NUL in {source_column}"
                )
            output_row[output_column] = value

        rows.append((epa_id, output_row))
        seen_ids.add(epa_id)
        makes.add(row["make"])
        years.append(year)

    if not rows:
        raise CatalogError("source CSV contains no vehicle rows")

    rows.sort(key=lambda item: item[0])
    output = io.StringIO(newline="")
    writer = csv.DictWriter(
        output,
        fieldnames=OUTPUT_COLUMNS,
        lineterminator="\n",
        extrasaction="raise",
    )
    writer.writeheader()
    writer.writerows(row for _, row in rows)
    catalog = output.getvalue().encode("utf-8")
    statistics = {
        "row_count": len(rows),
        "unique_make_count": len(makes),
        "year_min": min(years),
        "year_max": max(years),
    }
    return catalog, statistics


def build_manifest(
    *,
    archive: bytes,
    catalog: bytes,
    response_headers: Mapping[str, str],
    statistics: Mapping[str, int],
    retrieved_at: str,
) -> dict[str, object]:
    return {
        "schema_version": 2,
        "dataset": "U.S. EPA FuelEconomy.gov Find-a-Car vehicle configurations",
        "source": {
            "archive_url": SOURCE_URL,
            "landing_page": SOURCE_PAGE,
            "last_modified": response_headers.get("last-modified"),
            "retrieved_at_utc": retrieved_at,
            "sha256": sha256_bytes(archive),
        },
        "coverage": {
            "market": "United States",
            "model_year_policy": "1984 through the latest configurations in the source snapshot",
            "vehicle_scope": "FuelEconomy.gov Find-a-Car configurations",
            "does_not_assert": [
                "global make/model completeness",
                "curb weight",
                "torque",
                "drag coefficient",
                "volumetric efficiency",
            ],
        },
        "output": {
            "file": CATALOG_FILENAME,
            "sha256": sha256_bytes(catalog),
            "size_bytes": len(catalog),
            "columns": list(OUTPUT_COLUMNS),
            **statistics,
        },
    }


def manifest_bytes(manifest: Mapping[str, object]) -> bytes:
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as output:
            temporary_path = Path(output.name)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def comparable_manifest(manifest: Mapping[str, object]) -> dict[str, object]:
    comparable = json.loads(json.dumps(manifest))
    source = comparable.get("source")
    if isinstance(source, dict):
        source.pop("retrieved_at_utc", None)
    return comparable


def check_outputs(
    output_dir: Path,
    expected_catalog: bytes,
    expected_manifest: Mapping[str, object],
) -> bool:
    catalog_path = output_dir / CATALOG_FILENAME
    manifest_path = output_dir / MANIFEST_FILENAME
    errors: list[str] = []

    try:
        actual_catalog = catalog_path.read_bytes()
    except OSError as error:
        errors.append(f"cannot read {catalog_path}: {error}")
    else:
        if actual_catalog != expected_catalog:
            errors.append(f"{catalog_path} differs from the current official source")

    try:
        actual_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"cannot read {manifest_path}: {error}")
    else:
        if comparable_manifest(actual_manifest) != comparable_manifest(expected_manifest):
            errors.append(
                f"{manifest_path} differs from the current official source "
                "(retrieved_at_utc ignored)"
            )

    for error in errors:
        print(f"ERROR: {error}")
    return not errors


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="download and regenerate in memory, then compare with checked-in outputs",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"output directory (default: {DEFAULT_OUTPUT_DIR})",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    retrieved_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()

    try:
        archive, response_headers = download_archive(SOURCE_URL)
        source_csv = read_source_csv(archive)
        catalog, statistics = normalized_catalog(source_csv)
        manifest = build_manifest(
            archive=archive,
            catalog=catalog,
            response_headers=response_headers,
            statistics=statistics,
            retrieved_at=retrieved_at,
        )
    except CatalogError as error:
        print(f"ERROR: {error}")
        return 1

    output_dir = args.output_dir.resolve()
    if args.check:
        if not check_outputs(output_dir, catalog, manifest):
            return 1
        print("Catalog is reproducible and current (retrieved_at_utc ignored).")
    else:
        write_atomic(output_dir / CATALOG_FILENAME, catalog)
        write_atomic(output_dir / MANIFEST_FILENAME, manifest_bytes(manifest))
        print(f"Wrote {output_dir / CATALOG_FILENAME}")
        print(f"Wrote {output_dir / MANIFEST_FILENAME}")

    print(
        "source_sha256={source_sha256} rows={rows} unique_makes={makes} "
        "years={year_min}-{year_max} catalog_bytes={catalog_bytes}".format(
            source_sha256=sha256_bytes(archive),
            rows=statistics["row_count"],
            makes=statistics["unique_make_count"],
            year_min=statistics["year_min"],
            year_max=statistics["year_max"],
            catalog_bytes=len(catalog),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
