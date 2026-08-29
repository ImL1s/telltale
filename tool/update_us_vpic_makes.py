#!/usr/bin/env python3
"""Update the offline U.S. NHTSA vPIC registered-make identity snapshot.

The endpoint contains make/manufacturer identities registered for vehicles
intended for sale or importation into the United States. It is not a global
consumer-brand catalog and supplies no model or physical vehicle parameters.
"""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
from typing import Mapping, Sequence
import urllib.request


SOURCE_URL = "https://vpic.nhtsa.dot.gov/api/vehicles/GetAllMakes?format=json"
USER_AGENT = "TelltaleVehicleCatalogUpdater/1.0 (+https://github.com/ImL1s/telltale)"
DOWNLOAD_TIMEOUT_SECONDS = 120

SCRIPT_DIR = Path(__file__).resolve().parent
APP_DIR = SCRIPT_DIR.parent
DEFAULT_OUTPUT_DIR = APP_DIR / "assets" / "vehicle_catalog"
CATALOG_FILENAME = "us_vpic_makes.csv"
MANIFEST_FILENAME = "us_vpic_makes.manifest.json"
OUTPUT_COLUMNS = ("make_id", "make_name")
ROOT_FIELDS = {"Count", "Message", "SearchCriteria", "Results"}
RESULT_FIELDS = {"Make_ID", "Make_Name"}


class CatalogError(RuntimeError):
    """Raised when the official response cannot be safely normalized."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def download_source(url: str) -> tuple[bytes, Mapping[str, str]]:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(
            request,
            timeout=DOWNLOAD_TIMEOUT_SECONDS,
        ) as response:
            source = response.read()
            headers = {key.lower(): value for key, value in response.headers.items()}
    except OSError as error:
        raise CatalogError(f"download failed: {error}") from error

    if not source:
        raise CatalogError("download returned an empty response")
    return source, headers


def normalized_catalog(source: bytes) -> tuple[bytes, dict[str, int]]:
    try:
        document = json.loads(source.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CatalogError(f"source is not valid UTF-8 JSON: {error}") from error

    if not isinstance(document, dict):
        raise CatalogError("source JSON root must be an object")
    if set(document) != ROOT_FIELDS:
        missing = sorted(ROOT_FIELDS - set(document))
        extra = sorted(set(document) - ROOT_FIELDS)
        raise CatalogError(f"source JSON root schema mismatch; missing={missing}, extra={extra}")

    count = document["Count"]
    results = document["Results"]
    if isinstance(count, bool) or not isinstance(count, int) or count <= 0:
        raise CatalogError("Count must be a positive integer")
    if not isinstance(document["Message"], str):
        raise CatalogError("Message must be a string")
    if document["SearchCriteria"] is not None and not isinstance(
        document["SearchCriteria"], str
    ):
        raise CatalogError("SearchCriteria must be null or a string")
    if not isinstance(results, list):
        raise CatalogError("Results must be an array")
    if count != len(results):
        raise CatalogError(f"Count {count} does not match Results length {len(results)}")

    rows: list[tuple[int, str]] = []
    seen_ids: set[int] = set()
    seen_names: set[str] = set()
    for index, result in enumerate(results):
        row_number = index + 1
        if not isinstance(result, dict) or set(result) != RESULT_FIELDS:
            raise CatalogError(f"result {row_number} does not match the vPIC make schema")
        make_id = result["Make_ID"]
        make_name = result["Make_Name"]
        if isinstance(make_id, bool) or not isinstance(make_id, int) or make_id <= 0:
            raise CatalogError(f"result {row_number} has an invalid Make_ID")
        if not isinstance(make_name, str):
            raise CatalogError(f"result {row_number} has a non-string Make_Name")
        if "\x00" in make_name:
            raise CatalogError(f"result {row_number} contains a NUL in Make_Name")
        normalized_name = make_name.strip()
        if not normalized_name:
            raise CatalogError(f"result {row_number} has an empty Make_Name")
        if make_id in seen_ids:
            raise CatalogError(f"source contains duplicate Make_ID {make_id}")
        if normalized_name in seen_names:
            raise CatalogError(f"source contains duplicate Make_Name {normalized_name!r}")
        rows.append((make_id, normalized_name))
        seen_ids.add(make_id)
        seen_names.add(normalized_name)

    rows.sort(key=lambda row: row[0])
    output = io.StringIO(newline="")
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(OUTPUT_COLUMNS)
    writer.writerows(rows)
    catalog = output.getvalue().encode("utf-8")
    return catalog, {"row_count": len(rows)}


def build_manifest(
    *,
    source: bytes,
    catalog: bytes,
    response_headers: Mapping[str, str],
    statistics: Mapping[str, int],
    retrieved_at: str,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "dataset": "U.S. NHTSA vPIC make records",
        "source": {
            "endpoint_url": SOURCE_URL,
            "etag": response_headers.get("etag"),
            "last_modified": response_headers.get("last-modified"),
            "retrieved_at_utc": retrieved_at,
            "sha256": sha256_bytes(source),
        },
        "coverage": {
            "market": "United States",
            "vehicle_scope": (
                "vPIC make/manufacturer identities registered for vehicles intended "
                "for sale or importation into the United States"
            ),
            "identity_semantics": (
                "vPIC make record; entries are not necessarily distinct "
                "consumer-facing brands"
            ),
            "does_not_assert": [
                "global brand completeness",
                "consumer model availability",
                "vehicle specifications",
                "physical parameters",
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
        source, response_headers = download_source(SOURCE_URL)
        catalog, statistics = normalized_catalog(source)
        manifest = build_manifest(
            source=source,
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
        "source_sha256={source_sha256} rows={rows} catalog_bytes={catalog_bytes}".format(
            source_sha256=sha256_bytes(source),
            rows=statistics["row_count"],
            catalog_bytes=len(catalog),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
