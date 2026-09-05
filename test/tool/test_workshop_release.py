#!/usr/bin/env python3
import json
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool" / "workshop"))

from run_release_gate import evaluate, load_profiles  # noqa: E402


class WorkshopReleaseTest(unittest.TestCase):
    def setUp(self):
        self.profiles = load_profiles(ROOT / "tool" / "workshop" / "release_profiles.json")
        self.available = json.loads(
            (ROOT / "test" / "tool" / "fixtures" / "core_obd_available.json").read_text()
        )

    def test_exit_a_passes_without_field_artifacts(self):
        code, message = evaluate("core-obd-available", self.profiles, self.available)
        self.assertEqual(code, 0)
        self.assertEqual(message, "available")

    def test_exit_b_fails_without_field_artifacts(self):
        code, message = evaluate("field-qualified", self.profiles, self.available)
        self.assertEqual(code, 1)
        self.assertIn("field", message)

    def test_simulation_cannot_be_field(self):
        evidence = {
            **self.available,
            "fieldArtifacts": [
                {"kind": "simulation", "sha256": "a" * 64},
            ],
        }
        code, message = evaluate("field-qualified", self.profiles, evidence)
        self.assertEqual(code, 1)
        self.assertIn("kind", message)

    def test_missing_kind_cannot_be_field(self):
        evidence = {
            **self.available,
            "fieldArtifacts": [{"sha256": "a" * 64}],
        }
        code, _ = evaluate("field-qualified", self.profiles, evidence)
        self.assertEqual(code, 1)

    def test_physical_artifact_passes_b(self):
        evidence = {
            **self.available,
            "fieldArtifacts": [
                {"kind": "physicalVehicle", "sha256": "a" * 64},
            ],
        }
        code, message = evaluate("field-qualified", self.profiles, evidence)
        self.assertEqual(code, 0)
        self.assertEqual(message, "field-qualified")

    def test_software_skip_fails_a(self):
        evidence = {**self.available, "softwareSkipped": True}
        code, _ = evaluate("core-obd-available", self.profiles, evidence)
        self.assertEqual(code, 1)

    def test_string_false_does_not_pass_software(self):
        evidence = {**self.available, "softwarePass": "false"}
        code, message = evaluate("core-obd-available", self.profiles, evidence)
        self.assertEqual(code, 1)
        self.assertIn("boolean", message)


if __name__ == "__main__":
    unittest.main()
