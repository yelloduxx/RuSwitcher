from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "publish_release.py"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("publish_release", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class PublishReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.candidate = self.root / "candidate.dmg"
        self.destination = self.root / "RuSwitcher-4.0.0.dmg"
        self.version_json = self.root / "version.json"
        self.cask = self.root / "ruswitcher.rb"
        self.candidate.write_bytes(b"verified-new-dmg")
        self.destination.write_bytes(b"previous-public-dmg")
        self.version_json.write_text(
            '{\n  "version": "4.0.0",\n  "build": "89",\n  "sha256": "old"\n}\n'
        )
        self.cask.write_text('version "4.0.0"\nsha256 "old"\n')
        self.version_json.chmod(0o640)
        self.cask.chmod(0o600)
        self.digest = hashlib.sha256(self.candidate.read_bytes()).hexdigest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _publish(self, **kwargs: object) -> None:
        MODULE.publish_release(
            self.candidate,
            self.destination,
            self.version_json,
            self.cask,
            version="4.0.0",
            build=89,
            sha256=self.digest,
            **kwargs,
        )

    def _snapshot(self) -> tuple[bytes, bytes, bytes, int, int]:
        return (
            self.destination.read_bytes(),
            self.version_json.read_bytes(),
            self.cask.read_bytes(),
            stat.S_IMODE(self.version_json.stat().st_mode),
            stat.S_IMODE(self.cask.stat().st_mode),
        )

    def test_success_publishes_matching_dmg_and_metadata(self) -> None:
        self._publish()

        self.assertEqual(self.destination.read_bytes(), b"verified-new-dmg")
        self.assertFalse(self.candidate.exists())
        self.assertEqual(json.loads(self.version_json.read_text())["sha256"], self.digest)
        self.assertIn(f'sha256 "{self.digest}"', self.cask.read_text())
        self.assertEqual(stat.S_IMODE(self.version_json.stat().st_mode), 0o640)
        self.assertEqual(stat.S_IMODE(self.cask.stat().st_mode), 0o600)

    def test_failure_after_each_commit_step_restores_all_public_files(self) -> None:
        for failure_index in range(3):
            with self.subTest(failure_index=failure_index):
                # Each subtest uses an independent complete publication state.
                self.candidate.write_bytes(b"verified-new-dmg")
                self.destination.write_bytes(b"previous-public-dmg")
                self.version_json.write_text(
                    '{\n  "version": "4.0.0",\n  "build": "89",\n  "sha256": "old"\n}\n'
                )
                self.cask.write_text('version "4.0.0"\nsha256 "old"\n')
                self.version_json.chmod(0o640)
                self.cask.chmod(0o600)
                before = self._snapshot()

                def fail(index: int, _path: Path) -> None:
                    if index == failure_index:
                        raise OSError(f"failure after replacement {index}")

                with self.assertRaisesRegex(OSError, "failure after replacement"):
                    self._publish(_after_replace=fail)

                self.assertEqual(self._snapshot(), before)

    def test_hash_mismatch_mutates_nothing(self) -> None:
        before = self._snapshot()
        with self.assertRaisesRegex(ValueError, "sha256"):
            MODULE.publish_release(
                self.candidate,
                self.destination,
                self.version_json,
                self.cask,
                version="4.0.0",
                build=89,
                sha256="0" * 64,
            )
        self.assertEqual(self._snapshot(), before)
        self.assertTrue(self.candidate.exists())

    def test_failure_removes_new_destination_when_no_previous_dmg_exists(self) -> None:
        self.destination.unlink()
        original_version = self.version_json.read_bytes()
        original_cask = self.cask.read_bytes()

        def fail_after_dmg(_index: int, _path: Path) -> None:
            raise OSError("fail after new DMG")

        with self.assertRaisesRegex(OSError, "fail after new DMG"):
            self._publish(_after_replace=fail_after_dmg)

        self.assertFalse(self.destination.exists())
        self.assertEqual(self.version_json.read_bytes(), original_version)
        self.assertEqual(self.cask.read_bytes(), original_cask)

    def test_sigterm_during_publication_restores_all_public_files(self) -> None:
        before = self._snapshot()
        code = """
import os
from pathlib import Path
import signal
import sys
sys.path.insert(0, sys.argv[1])
from publish_release import publish_release

def interrupt(index, path):
    if index == 0:
        os.kill(os.getpid(), signal.SIGTERM)

publish_release(
    Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]), Path(sys.argv[5]),
    version="4.0.0", build=89, sha256=sys.argv[6], _after_replace=interrupt,
)
"""
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                code,
                str(SCRIPTS),
                str(self.candidate),
                str(self.destination),
                str(self.version_json),
                str(self.cask),
                self.digest,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TransactionInterrupted", result.stderr)
        self.assertEqual(self._snapshot(), before)


class CreateDMGReleaseFlowTests(unittest.TestCase):
    def test_final_payload_is_verified_before_transactional_publication(self) -> None:
        script = (SCRIPTS.parent / "create_dmg.sh").read_text()
        main_flow = script[script.index("# 10. Notarize with Apple") :]
        verification = main_flow.index("verify_final_dmg_payload")
        digest = main_flow.index('DMG_SHA=$(shasum -a 256 "$DMG_BUILD_PATH"')
        publication = main_flow.index("run_publication_transaction")

        self.assertLess(verification, digest)
        self.assertLess(digest, publication)
        self.assertIn('scripts/publish_release.py" "$@"', script)
        self.assertIn('spctl --assess --type execute --verbose=4 "$payload_app"', script)
        self.assertIn('signature_team" != "$EXPECTED_TEAM_ID', script)


if __name__ == "__main__":
    unittest.main()
