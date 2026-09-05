#!/usr/bin/env python3
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool" / "workshop"))

from validate_capabilities import validate  # noqa: E402


class WorkshopCapabilitiesTest(unittest.TestCase):
    def test_bundled_matrix_is_valid(self):
        path = ROOT / "docs" / "workshop" / "capabilities.json"
        self.assertEqual(validate(path), [])

    def test_forged_field_verified_without_hash_fails(self):
        import json
        import tempfile

        payload = json.loads(
            (ROOT / "docs" / "workshop" / "capabilities.json").read_text()
        )
        payload["capabilities"][0]["evidence"] = "fieldVerified"
        payload["capabilities"][0].pop("fieldArtifactSha256", None)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(payload, handle)
            path = Path(handle.name)
        errors = validate(path)
        self.assertTrue(any("fieldVerified" in error for error in errors))

    def test_field_verified_rejects_non_sha256_digest(self):
        import json
        import tempfile

        payload = json.loads(
            (ROOT / "docs" / "workshop" / "capabilities.json").read_text()
        )
        payload["capabilities"][0]["evidence"] = "fieldVerified"
        payload["capabilities"][0]["fieldArtifactSha256"] = "NOT-A-DIGEST"
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(payload, handle)
            path = Path(handle.name)
        errors = validate(path)
        self.assertTrue(any("64-char lowercase SHA-256" in error for error in errors))

    def test_usable_clear_without_gates_fails(self):
        import json
        import tempfile

        payload = json.loads(
            (ROOT / "docs" / "workshop" / "capabilities.json").read_text()
        )
        payload["capabilities"][0]["operationRisk"] = "clear"
        payload["capabilities"][0]["availability"] = "usable"
        payload["capabilities"][0].pop("requiresClearSnapshot", None)
        payload["capabilities"][0].pop("requiresUserConfirm", None)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(payload, handle)
            path = Path(handle.name)
        errors = validate(path)
        self.assertTrue(any("usable clear" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
