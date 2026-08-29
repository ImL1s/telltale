from __future__ import annotations

import csv
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


APP_DIR = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_DIR / "tool" / "update_us_vpic_makes.py"
FIXTURE_PATH = Path(__file__).parent / "fixtures" / "us_vpic_makes_sample.json"


def load_updater():
    spec = importlib.util.spec_from_file_location("update_us_vpic_makes", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeResponse:
    def __init__(self, body: bytes) -> None:
        self._body = body
        self.headers = {"Content-Type": "application/json"}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self) -> bytes:
        return self._body


class VpicMakesUpdaterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.updater = load_updater()
        cls.source = FIXTURE_PATH.read_bytes()

    def test_normalizes_fixture_deterministically_by_make_id(self) -> None:
        catalog, statistics = self.updater.normalized_catalog(self.source)

        rows = list(csv.DictReader(io.StringIO(catalog.decode("utf-8"))))
        self.assertEqual(
            rows,
            [
                {"make_id": "101", "make_name": "ALPHA AUTO"},
                {"make_id": "502", "make_name": "BETA MOTORS"},
                {"make_id": "900", "make_name": "ZETA WORKS"},
            ],
        )
        self.assertEqual(statistics, {"row_count": 3})
        self.assertTrue(catalog.endswith(b"\n"))

    def test_rejects_invalid_root_schema_count_and_results(self) -> None:
        invalid_documents = [
            [],
            {"Count": 0},
            {"Count": "1", "Results": []},
            {"Count": 1, "Results": []},
            {"Count": 0, "Results": "not-a-list"},
        ]
        for document in invalid_documents:
            with self.subTest(document=document):
                with self.assertRaises(self.updater.CatalogError):
                    self.updater.normalized_catalog(json.dumps(document).encode())

    def test_rejects_invalid_ids_names_duplicates_extra_fields_and_nul(self) -> None:
        invalid_rows = [
            [{"Make_ID": 0, "Make_Name": "ZERO"}],
            [{"Make_ID": -1, "Make_Name": "NEGATIVE"}],
            [{"Make_ID": True, "Make_Name": "BOOLEAN"}],
            [{"Make_ID": "1", "Make_Name": "TEXT ID"}],
            [{"Make_ID": 1, "Make_Name": ""}],
            [{"Make_ID": 1, "Make_Name": "   "}],
            [{"Make_ID": 1, "Make_Name": "BAD\u0000NAME"}],
            [{"Make_ID": 1, "Make_Name": "A", "Unexpected": "field"}],
            [
                {"Make_ID": 1, "Make_Name": "A"},
                {"Make_ID": 1, "Make_Name": "B"},
            ],
            [
                {"Make_ID": 1, "Make_Name": "SAME"},
                {"Make_ID": 2, "Make_Name": "SAME"},
            ],
        ]
        for rows in invalid_rows:
            with self.subTest(rows=rows):
                document = {"Count": len(rows), "Results": rows}
                with self.assertRaises(self.updater.CatalogError):
                    self.updater.normalized_catalog(json.dumps(document).encode())

    def test_download_sets_user_agent_accept_and_timeout(self) -> None:
        observed = {}

        def fake_urlopen(request, *, timeout):
            observed["request"] = request
            observed["timeout"] = timeout
            return FakeResponse(self.source)

        with mock.patch.object(self.updater.urllib.request, "urlopen", fake_urlopen):
            raw, headers = self.updater.download_source(self.updater.SOURCE_URL)

        self.assertEqual(raw, self.source)
        self.assertEqual(observed["timeout"], self.updater.DOWNLOAD_TIMEOUT_SECONDS)
        request_headers = dict(observed["request"].header_items())
        self.assertEqual(request_headers["User-agent"], self.updater.USER_AGENT)
        self.assertEqual(request_headers["Accept"], "application/json")
        self.assertEqual(headers["content-type"], "application/json")

    def test_manifest_hashes_raw_and_normalized_data_and_states_scope(self) -> None:
        catalog, statistics = self.updater.normalized_catalog(self.source)
        manifest = self.updater.build_manifest(
            source=self.source,
            catalog=catalog,
            response_headers={"etag": '"fixture"'},
            statistics=statistics,
            retrieved_at="2026-08-29T00:00:00+00:00",
        )

        self.assertEqual(manifest["source"]["sha256"], self.updater.sha256_bytes(self.source))
        self.assertEqual(manifest["output"]["sha256"], self.updater.sha256_bytes(catalog))
        self.assertEqual(manifest["output"]["row_count"], 3)
        self.assertEqual(manifest["dataset"], "U.S. NHTSA vPIC make records")
        self.assertEqual(
            manifest["coverage"]["vehicle_scope"],
            "vPIC make/manufacturer identities registered for vehicles intended "
            "for sale or importation into the United States",
        )
        assertions = " ".join(manifest["coverage"]["does_not_assert"])
        self.assertIn("global", assertions.lower())
        self.assertIn("vehicle specifications", assertions.lower())
        self.assertIn("physical parameters", assertions.lower())

    def test_check_ignores_only_retrieval_time(self) -> None:
        catalog, statistics = self.updater.normalized_catalog(self.source)
        manifest = self.updater.build_manifest(
            source=self.source,
            catalog=catalog,
            response_headers={},
            statistics=statistics,
            retrieved_at="2026-08-29T00:00:00+00:00",
        )
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            (output_dir / self.updater.CATALOG_FILENAME).write_bytes(catalog)
            written_manifest = json.loads(json.dumps(manifest))
            written_manifest["source"]["retrieved_at_utc"] = "2000-01-01T00:00:00+00:00"
            (output_dir / self.updater.MANIFEST_FILENAME).write_text(
                json.dumps(written_manifest), encoding="utf-8"
            )
            self.assertTrue(self.updater.check_outputs(output_dir, catalog, manifest))

            written_manifest["coverage"]["market"] = "Global"
            (output_dir / self.updater.MANIFEST_FILENAME).write_text(
                json.dumps(written_manifest), encoding="utf-8"
            )
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(
                    self.updater.check_outputs(output_dir, catalog, manifest)
                )

    def test_atomic_write_replaces_output_without_temp_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "catalog.csv"
            output.write_bytes(b"old")
            self.updater.write_atomic(output, b"new")
            self.assertEqual(output.read_bytes(), b"new")
            self.assertEqual(list(Path(directory).glob("*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
