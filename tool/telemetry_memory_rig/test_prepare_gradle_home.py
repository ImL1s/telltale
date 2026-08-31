import hashlib
import json
import os
import pathlib
import tempfile
import unittest

from prepare_gradle_home import distribution_key, prepare


URL = "https://services.gradle.org/distributions/gradle-9.3.1-all.zip"
FILENAME = "gradle-9.3.1-all.zip"


class PrepareGradleHomeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.destination = self.root / "gradle-home"
        self.evidence = self.root / "evidence.json"
        self.properties = self.root / "gradle-wrapper.properties"

    def tearDown(self):
        self.temporary.cleanup()

    def _write_properties(self, digest: str) -> None:
        self.properties.write_text(
            "distributionBase=GRADLE_USER_HOME\n"
            "distributionPath=wrapper/dists\n"
            "zipStoreBase=GRADLE_USER_HOME\n"
            "zipStorePath=wrapper/dists\n"
            "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.3.1-all.zip\n"
            f"distributionSha256Sum={digest}\n",
            encoding="utf-8",
        )

    def _cache_zip(self, content: bytes) -> pathlib.Path:
        path = self.cache / "wrapper/dists/gradle-9.3.1-all/old-key" / FILENAME
        path.parent.mkdir(parents=True)
        path.write_bytes(content)
        return path

    def test_matching_cache_is_copied_to_canonical_wrapper_destination(self):
        content = b"verified Gradle distribution"
        digest = hashlib.sha256(content).hexdigest()
        cached = self._cache_zip(content)
        self._write_properties(digest)

        result = prepare(
            wrapper_properties=self.properties,
            destination=self.destination,
            evidence=self.evidence,
            cache_root=self.cache,
        )

        self.assertEqual(distribution_key(URL), "9ot9r568e8zfvvd4mn8rbu1j0")
        expected = (
            self.destination
            / "wrapper/dists/gradle-9.3.1-all"
            / distribution_key(URL)
            / FILENAME
        )
        self.assertEqual(expected.read_bytes(), content)
        self.assertEqual(stat_mode(self.destination), 0o700)
        self.assertEqual(result["source"], "cache")
        self.assertEqual(result["cachedZip"], str(cached.resolve()))
        self.assertEqual(result["destinationZip"], str(expected.resolve()))
        self.assertEqual(json.loads(self.evidence.read_text()), result)

    def test_mismatched_cached_zip_is_rejected_and_destination_removed(self):
        self._cache_zip(b"poisoned")
        self._write_properties(hashlib.sha256(b"expected").hexdigest())
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            prepare(
                wrapper_properties=self.properties,
                destination=self.destination,
                evidence=self.evidence,
                cache_root=self.cache,
            )
        self.assertFalse(self.destination.exists())
        self.assertFalse(self.evidence.exists())

    def test_symlinked_cache_entry_is_rejected(self):
        content = b"distribution"
        real = self.root / "real.zip"
        real.write_bytes(content)
        link = self.cache / FILENAME
        link.symlink_to(real)
        self._write_properties(hashlib.sha256(content).hexdigest())
        with self.assertRaisesRegex(ValueError, "symlink"):
            prepare(
                wrapper_properties=self.properties,
                destination=self.destination,
                evidence=self.evidence,
                cache_root=self.cache,
            )
        self.assertFalse(self.destination.exists())

    def test_symlinked_cache_ancestor_is_rejected(self):
        real_cache = self.root / "real-cache"
        real_cache.mkdir()
        linked_cache = self.root / "linked-cache"
        linked_cache.symlink_to(real_cache, target_is_directory=True)
        self._write_properties(hashlib.sha256(b"unused").hexdigest())
        with self.assertRaisesRegex(ValueError, "symlinked cache root"):
            prepare(
                wrapper_properties=self.properties,
                destination=self.destination,
                evidence=self.evidence,
                cache_root=linked_cache,
            )
        self.assertFalse(self.destination.exists())

    def test_stale_destination_is_rejected_without_modification(self):
        self.destination.mkdir()
        marker = self.destination / "keep"
        marker.write_text("stale", encoding="utf-8")
        self._write_properties(hashlib.sha256(b"unused").hexdigest())
        with self.assertRaisesRegex(ValueError, "fresh"):
            prepare(
                wrapper_properties=self.properties,
                destination=self.destination,
                evidence=self.evidence,
                cache_root=None,
            )
        self.assertEqual(marker.read_text(encoding="utf-8"), "stale")

    def test_missing_cached_zip_leaves_fresh_home_for_wrapper_download(self):
        digest = hashlib.sha256(b"downloaded later").hexdigest()
        self._write_properties(digest)
        result = prepare(
            wrapper_properties=self.properties,
            destination=self.destination,
            evidence=self.evidence,
            cache_root=self.cache,
        )
        self.assertEqual(result["source"], "download")
        self.assertIsNone(result["cachedZip"])
        self.assertFalse(pathlib.Path(result["destinationZip"]).exists())
        self.assertEqual(stat_mode(self.destination), 0o700)

    def test_multiple_matching_cache_entries_are_rejected_as_ambiguous(self):
        content = b"distribution"
        self._cache_zip(content)
        duplicate = self.cache / "second" / FILENAME
        duplicate.parent.mkdir()
        duplicate.write_bytes(content)
        self._write_properties(hashlib.sha256(content).hexdigest())
        with self.assertRaisesRegex(ValueError, "multiple cached"):
            prepare(
                wrapper_properties=self.properties,
                destination=self.destination,
                evidence=self.evidence,
                cache_root=self.cache,
            )
        self.assertFalse(self.destination.exists())

    def test_uppercase_sha_or_extra_global_config_property_is_rejected(self):
        self._write_properties("A" * 64)
        with self.assertRaisesRegex(ValueError, "lowercase"):
            prepare(
                wrapper_properties=self.properties,
                destination=self.destination,
                evidence=self.evidence,
                cache_root=None,
            )
        self.properties.write_text(
            self.properties.read_text(encoding="utf-8") + "systemProp.http.proxyHost=evil\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "schema mismatch"):
            prepare(
                wrapper_properties=self.properties,
                destination=self.destination,
                evidence=self.evidence,
                cache_root=None,
            )


def stat_mode(path: pathlib.Path) -> int:
    return os.stat(path, follow_symlinks=False).st_mode & 0o777


if __name__ == "__main__":
    unittest.main()
