from __future__ import annotations

import contextlib
import csv
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock
import zipfile


APP_DIR = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_DIR / "tool" / "update_us_vehicle_catalog.py"
FIXTURE_PATH = Path(__file__).parent / "fixtures" / "us_epa_vehicles_sample.csv"


def load_updater():
    spec = importlib.util.spec_from_file_location(
        "update_us_vehicle_catalog", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def zip_bytes(*members: tuple[str, bytes]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, mode="w", compression=zipfile.ZIP_STORED) as bundle:
        for name, data in members:
            entry = zipfile.ZipInfo(name, date_time=(2026, 8, 29, 0, 0, 0))
            entry.external_attr = 0o100644 << 16
            bundle.writestr(entry, data)
    return output.getvalue()


def csv_without_column(source: str, column: str) -> str:
    reader = csv.DictReader(io.StringIO(source))
    fieldnames = [name for name in reader.fieldnames or [] if name != column]
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    for row in reader:
        writer.writerow({name: row[name] for name in fieldnames})
    return output.getvalue()


def csv_with_rows(fieldnames: tuple[str, ...], rows: list[dict[str, str]]) -> str:
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


class UsVehicleCatalogUpdaterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.updater = load_updater()
        cls.source = FIXTURE_PATH.read_text(encoding="utf-8")
        cls.archive = zip_bytes(
            (cls.updater.ARCHIVE_MEMBER, cls.source.encode("utf-8"))
        )

    def test_normalizes_fixture_deterministically_by_epa_id(self) -> None:
        first_catalog, first_statistics = self.updater.normalized_catalog(self.source)
        second_catalog, second_statistics = self.updater.normalized_catalog(self.source)

        rows = list(csv.DictReader(io.StringIO(first_catalog.decode("utf-8"))))
        self.assertEqual([row["epa_id"] for row in rows], ["12", "205", "300"])
        self.assertEqual(rows[1]["alternative_vehicle_type"], "EV")
        self.assertEqual(rows[2]["alternative_vehicle_type"], "Hybrid")
        self.assertEqual(rows[2]["model"], "Comet, Touring")
        self.assertEqual(first_catalog, second_catalog)
        self.assertEqual(first_statistics, second_statistics)
        self.assertEqual(
            first_statistics,
            {
                "row_count": 3,
                "unique_make_count": 3,
                "year_min": 1984,
                "year_max": 2024,
            },
        )
        self.assertEqual(
            self.updater.sha256_bytes(first_catalog),
            "f1a4bdfaa3e74c94c1b76eac33b7b61b1df01979f99be1564612154cafbb7fc7",
        )
        self.assertTrue(first_catalog.endswith(b"\n"))

    def test_manifest_hashes_archive_and_catalog_and_states_limited_scope(self) -> None:
        catalog, statistics = self.updater.normalized_catalog(self.source)
        manifest = self.updater.build_manifest(
            archive=self.archive,
            catalog=catalog,
            response_headers={"last-modified": "Sat, 29 Aug 2026 00:00:00 GMT"},
            statistics=statistics,
            retrieved_at="2026-08-29T00:00:00+00:00",
        )

        self.assertEqual(manifest["schema_version"], 2)
        self.assertEqual(
            manifest["source"]["sha256"], self.updater.sha256_bytes(self.archive)
        )
        self.assertEqual(
            manifest["output"]["sha256"], self.updater.sha256_bytes(catalog)
        )
        self.assertEqual(manifest["output"]["size_bytes"], len(catalog))
        self.assertEqual(manifest["output"]["columns"], list(self.updater.OUTPUT_COLUMNS))
        self.assertEqual(manifest["coverage"]["market"], "United States")
        self.assertEqual(
            manifest["coverage"]["vehicle_scope"],
            "FuelEconomy.gov Find-a-Car configurations",
        )
        exclusions = " ".join(manifest["coverage"]["does_not_assert"]).lower()
        for excluded_claim in (
            "global make/model completeness",
            "curb weight",
            "torque",
            "drag coefficient",
            "volumetric efficiency",
        ):
            self.assertIn(excluded_claim, exclusions)

    def test_rejects_each_required_missing_column_including_atv_type(self) -> None:
        for column in self.updater.SOURCE_COLUMNS:
            with self.subTest(column=column):
                source = csv_without_column(self.source, column)
                with self.assertRaisesRegex(
                    self.updater.CatalogError, "missing required columns"
                ):
                    self.updater.normalized_catalog(source)

    def test_rejects_duplicate_epa_id(self) -> None:
        reader = csv.DictReader(io.StringIO(self.source))
        rows = list(reader)
        rows[1]["id"] = rows[0]["id"]
        source = csv_with_rows(self.updater.SOURCE_COLUMNS, rows)

        with self.assertRaisesRegex(self.updater.CatalogError, "duplicate EPA id"):
            self.updater.normalized_catalog(source)

    def test_rejects_invalid_identifiers_years_and_identity_values(self) -> None:
        invalid_updates = [
            {"id": "not-an-id"},
            {"id": "0"},
            {"id": "-1"},
            {"year": "not-a-year"},
            {"year": "1983"},
            {"make": ""},
            {"model": ""},
            {"make": "Bad\x00Make"},
            {"atvType": "Bad\x00Type"},
        ]
        for updates in invalid_updates:
            with self.subTest(updates=updates):
                reader = csv.DictReader(io.StringIO(self.source))
                rows = list(reader)
                rows[0].update(updates)
                source = csv_with_rows(self.updater.SOURCE_COLUMNS, rows)
                with self.assertRaises(self.updater.CatalogError):
                    self.updater.normalized_catalog(source)

    def test_rejects_empty_catalog_and_rows_with_extra_columns(self) -> None:
        header_only = csv_with_rows(self.updater.SOURCE_COLUMNS, [])
        with self.assertRaisesRegex(self.updater.CatalogError, "no vehicle rows"):
            self.updater.normalized_catalog(header_only)

        lines = self.source.splitlines()
        lines[1] += ",extra"
        with self.assertRaisesRegex(self.updater.CatalogError, "extra columns"):
            self.updater.normalized_catalog("\n".join(lines) + "\n")

    def test_reads_only_the_exact_nonempty_utf8_archive_member(self) -> None:
        self.assertEqual(self.updater.read_source_csv(self.archive), self.source)

        invalid_archives = [
            b"not-a-zip",
            zip_bytes(),
            zip_bytes(("wrong.csv", self.source.encode("utf-8"))),
            zip_bytes(
                (self.updater.ARCHIVE_MEMBER, self.source.encode("utf-8")),
                ("unexpected.txt", b"extra"),
            ),
            zip_bytes((self.updater.ARCHIVE_MEMBER, b"")),
            zip_bytes((self.updater.ARCHIVE_MEMBER, b"\xff")),
        ]
        for archive in invalid_archives:
            with self.subTest(archive_sha256=self.updater.sha256_bytes(archive)):
                with self.assertRaises(self.updater.CatalogError):
                    self.updater.read_source_csv(archive)

    def test_atomic_write_replaces_file_with_stable_permissions_and_no_temp_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "catalog.csv"
            output.write_bytes(b"old")

            self.updater.write_atomic(output, b"new")

            self.assertEqual(output.read_bytes(), b"new")
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o644)
            self.assertEqual(list(Path(directory).glob(".*.tmp")), [])

    def test_atomic_write_preserves_old_file_and_cleans_temp_when_replace_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "catalog.csv"
            output.write_bytes(b"old")

            with mock.patch.object(
                self.updater.os, "replace", side_effect=OSError("replace failed")
            ):
                with self.assertRaisesRegex(OSError, "replace failed"):
                    self.updater.write_atomic(output, b"new")

            self.assertEqual(output.read_bytes(), b"old")
            self.assertEqual(list(Path(directory).glob(".*.tmp")), [])

    def test_check_accepts_only_retrieval_time_difference(self) -> None:
        catalog, statistics = self.updater.normalized_catalog(self.source)
        manifest = self.updater.build_manifest(
            archive=self.archive,
            catalog=catalog,
            response_headers={},
            statistics=statistics,
            retrieved_at="2026-08-29T00:00:00+00:00",
        )
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            (output_dir / self.updater.CATALOG_FILENAME).write_bytes(catalog)
            written_manifest = json.loads(json.dumps(manifest))
            written_manifest["source"]["retrieved_at_utc"] = (
                "2000-01-01T00:00:00+00:00"
            )
            (output_dir / self.updater.MANIFEST_FILENAME).write_text(
                json.dumps(written_manifest), encoding="utf-8"
            )

            self.assertTrue(self.updater.check_outputs(output_dir, catalog, manifest))

    def test_check_rejects_catalog_manifest_and_schema_drift(self) -> None:
        catalog, statistics = self.updater.normalized_catalog(self.source)
        manifest = self.updater.build_manifest(
            archive=self.archive,
            catalog=catalog,
            response_headers={},
            statistics=statistics,
            retrieved_at="2026-08-29T00:00:00+00:00",
        )
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            catalog_path = output_dir / self.updater.CATALOG_FILENAME
            manifest_path = output_dir / self.updater.MANIFEST_FILENAME
            catalog_path.write_bytes(catalog + b"drift")
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(
                    self.updater.check_outputs(output_dir, catalog, manifest)
                )

            catalog_path.write_bytes(catalog)
            drifted_manifest = json.loads(json.dumps(manifest))
            drifted_manifest["schema_version"] = 1
            manifest_path.write_text(json.dumps(drifted_manifest), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(
                    self.updater.check_outputs(output_dir, catalog, manifest)
                )

            manifest_path.write_text("not json", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(
                    self.updater.check_outputs(output_dir, catalog, manifest)
                )


if __name__ == "__main__":
    unittest.main()
