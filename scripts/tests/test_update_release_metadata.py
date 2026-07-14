import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "update_release_metadata.py"
SPEC = importlib.util.spec_from_file_location("update_release_metadata", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class UpdateReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.version_json = self.root / "version.json"
        self.cask = self.root / "ruswitcher.rb"
        self.version_json.write_text(
            '{\n  "version": "4.0.0",\n  "build": "89",\n  "sha256": "old"\n}\n'
        )
        self.cask.write_text('version "4.0.0"\nsha256 "old"\n')

    def tearDown(self):
        self.temporary.cleanup()

    def test_updates_both_files(self):
        digest = "a" * 64
        self.version_json.chmod(0o640)
        self.cask.chmod(0o600)

        MODULE.update_release_metadata(
            self.version_json,
            self.cask,
            version="4.0.0",
            build=89,
            sha256=digest,
        )

        self.assertIn(digest, self.version_json.read_text())
        self.assertEqual(
            self.cask.read_text(),
            f'version "4.0.0"\nsha256 "{digest}"\n',
        )
        self.assertEqual(stat.S_IMODE(self.version_json.stat().st_mode), 0o640)
        self.assertEqual(stat.S_IMODE(self.cask.stat().st_mode), 0o600)

    def test_validation_failure_changes_neither_file(self):
        original_version = self.version_json.read_bytes()
        self.cask.write_text('version "4.0.0"\n')
        original_cask = self.cask.read_bytes()

        with self.assertRaises(ValueError):
            MODULE.update_release_metadata(
                self.version_json,
                self.cask,
                version="4.0.0",
                build=89,
                sha256="b" * 64,
            )

        self.assertEqual(self.version_json.read_bytes(), original_version)
        self.assertEqual(self.cask.read_bytes(), original_cask)

    def test_duplicate_critical_json_fields_change_neither_file(self):
        cases = {
            "version": (
                '{"version":"4.0.0","version":"4.0.0",'
                '"build":"89","sha256":"old"}\n'
            ),
            "build": (
                '{"version":"4.0.0","build":"89","build":"89",'
                '"sha256":"old"}\n'
            ),
            "sha256": (
                '{"version":"4.0.0","build":"89","sha256":"old",'
                '"sha256":"old"}\n'
            ),
        }
        for field, content in cases.items():
            with self.subTest(field=field):
                self.version_json.write_text(content)
                original_version = self.version_json.read_bytes()
                original_cask = self.cask.read_bytes()

                with self.assertRaisesRegex(ValueError, f"duplicate '{field}'"):
                    MODULE.update_release_metadata(
                        self.version_json,
                        self.cask,
                        version="4.0.0",
                        build=89,
                        sha256="d" * 64,
                    )

                self.assertEqual(self.version_json.read_bytes(), original_version)
                self.assertEqual(self.cask.read_bytes(), original_cask)

    def test_duplicate_cask_fields_change_neither_file(self):
        cases = {
            "version": 'version "4.0.0"\nversion "4.0.0"\nsha256 "old"\n',
            "sha256": 'version "4.0.0"\nsha256 "old"\nsha256 "old"\n',
        }
        for field, content in cases.items():
            with self.subTest(field=field):
                self.cask.write_text(content)
                original_version = self.version_json.read_bytes()
                original_cask = self.cask.read_bytes()

                with self.assertRaisesRegex(ValueError, "exactly one"):
                    MODULE.update_release_metadata(
                        self.version_json,
                        self.cask,
                        version="4.0.0",
                        build=89,
                        sha256="e" * 64,
                    )

                self.assertEqual(self.version_json.read_bytes(), original_version)
                self.assertEqual(self.cask.read_bytes(), original_cask)

    def test_error_after_first_replace_rolls_back_metadata_pair(self):
        original_version = self.version_json.read_bytes()
        original_cask = self.cask.read_bytes()
        original_modes = (
            stat.S_IMODE(self.version_json.stat().st_mode),
            stat.S_IMODE(self.cask.stat().st_mode),
        )

        def fail_after_first_replace(index: int, _path: Path) -> None:
            if index == 0:
                raise OSError("injected publication failure")

        with self.assertRaisesRegex(OSError, "injected publication failure"):
            MODULE.update_release_metadata(
                self.version_json,
                self.cask,
                version="4.0.0",
                build=89,
                sha256="f" * 64,
                _after_replace=fail_after_first_replace,
            )

        self.assertEqual(self.version_json.read_bytes(), original_version)
        self.assertEqual(self.cask.read_bytes(), original_cask)
        self.assertEqual(
            (
                stat.S_IMODE(self.version_json.stat().st_mode),
                stat.S_IMODE(self.cask.stat().st_mode),
            ),
            original_modes,
        )

    def test_stale_version_changes_neither_file(self):
        original_version = self.version_json.read_bytes()
        original_cask = self.cask.read_bytes()

        with self.assertRaises(ValueError):
            MODULE.update_release_metadata(
                self.version_json,
                self.cask,
                version="4.0.1",
                build=89,
                sha256="c" * 64,
            )

        self.assertEqual(self.version_json.read_bytes(), original_version)
        self.assertEqual(self.cask.read_bytes(), original_cask)


if __name__ == "__main__":
    unittest.main()
