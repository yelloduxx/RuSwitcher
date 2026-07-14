from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "run_v3_1_fresh_domain_gate.py"
SPEC = importlib.util.spec_from_file_location("run_v3_1_fresh_domain_gate", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"unable to load {SCRIPT}")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class FreshDomainGateRegressionTests(unittest.TestCase):
    def test_failed_engine_run_cannot_reuse_stale_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            build = root / "build"
            bin_directory = root / "bin"
            build.mkdir()
            bin_directory.mkdir()

            report = build / "v3.1-fresh-domain-v3-report.json"
            traces = build / "v3.1-fresh-domain-v3-traces.jsonl"
            report.write_text('{"phrasePassed": 999}\n', encoding="utf-8")
            traces.write_text('{"steps": []}\n', encoding="utf-8")

            swift = bin_directory / "swift"
            swift.write_text("#!/bin/sh\nexit 23\n", encoding="utf-8")
            swift.chmod(0o755)

            fixtures = root / "fixtures.jsonl"
            fixtures.write_text("", encoding="utf-8")
            path = os.pathsep.join((str(bin_directory), os.environ.get("PATH", "")))
            with mock.patch.object(gate, "ROOT", root), mock.patch.object(
                gate, "BUILD", build
            ), mock.patch.object(gate, "FIXTURES", fixtures), mock.patch.dict(
                os.environ, {"PATH": path}
            ):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    gate.run_engine("v3")

            self.assertEqual(raised.exception.returncode, 23)
            self.assertFalse(report.exists())
            self.assertFalse(traces.exists())

    def test_exit_one_with_fresh_valid_outputs_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            build = root / "build"
            build.mkdir()
            report = build / "v3.1-fresh-domain-v3-report.json"
            traces = build / "v3.1-fresh-domain-v3-traces.jsonl"
            report.write_text('{"stale": true}\n', encoding="utf-8")
            traces.write_text('{"stale": true}\n', encoding="utf-8")

            fixtures = root / "fixtures.jsonl"
            fixture = {
                "id": "current-fixture",
                "initialLanguage": "en",
                "steps": [
                    {
                        "typed": "wrong",
                        "manualLanguage": "en",
                        "separator": " ",
                        "expected": "switch",
                        "expectedResolved": "right",
                    }
                ],
                "expectedText": "right ",
            }
            fixtures.write_text(json.dumps(fixture) + "\n", encoding="utf-8")

            fresh_report = {
                "engine": "v3",
                "total": 1,
                "passed": 0,
                "failed": 1,
                "phraseTotal": 1,
                "phrasePassed": 0,
            }
            fresh_trace = {
                "id": "current-fixture",
                "passed": False,
                "expectedText": "right ",
                "actualText": "wrong ",
                "steps": [
                    {
                        "typed": "wrong",
                        "sourceLanguage": "en",
                        "expectedVerdict": "switch",
                        "actualVerdict": "keep",
                        "expectedResolved": "right",
                        "actualResolved": "wrong",
                        "passed": False,
                        "latencyMicroseconds": 1.0,
                    }
                ],
            }

            def simulator_run(
                command: list[str],
                **kwargs: object,
            ) -> subprocess.CompletedProcess[str]:
                self.assertFalse(kwargs["check"])
                self.assertFalse(report.exists())
                self.assertFalse(traces.exists())
                run_report = Path(command[command.index("--output") + 1])
                run_traces = Path(command[command.index("--phrase-results") + 1])
                self.assertNotEqual(run_report, report)
                self.assertNotEqual(run_traces, traces)
                run_report.write_text(
                    json.dumps(fresh_report) + "\n",
                    encoding="utf-8",
                )
                run_traces.write_text(
                    json.dumps(fresh_trace) + "\n",
                    encoding="utf-8",
                )
                return subprocess.CompletedProcess(command, 1)

            with mock.patch.object(gate, "ROOT", root), mock.patch.object(
                gate, "BUILD", build
            ), mock.patch.object(gate, "FIXTURES", fixtures), mock.patch.object(
                gate.subprocess, "run", side_effect=simulator_run
            ):
                summary, counts = gate.run_engine("v3")

            self.assertEqual(summary, fresh_report)
            self.assertEqual(
                counts,
                {
                    "correct": 0,
                    "falsePositives": 0,
                    "wrongReplacements": 0,
                    "safeMisses": 1,
                },
            )
            self.assertEqual(
                json.loads(report.read_text(encoding="utf-8")),
                fresh_report,
            )
            self.assertEqual(
                json.loads(traces.read_text(encoding="utf-8")),
                fresh_trace,
            )

    def test_generate_rejects_mismatched_parallel_corpus_lengths(self) -> None:
        russian_sentence = (
            "\u043f\u0440\u0438\u0432\u0435\u0442 "
            "\u0434\u0440\u0443\u0433\u043e\u0439 "
            "\u0442\u0435\u043a\u0441\u0442"
        )
        cases = (
            (
                "english longer",
                "hello world again\nsecond english line\n",
                f"{russian_sentence}\n",
                "ru.txt ended before en.txt",
            ),
            (
                "russian longer",
                "hello world again\n",
                f"{russian_sentence}\n{russian_sentence}\n",
                "en.txt ended before ru.txt",
            ),
        )
        manifest = {
            "englishEntry": "en.txt",
            "russianEntry": "ru.txt",
            "maximumPhrases": 1,
            "maximumTokensPerPhrase": 8,
            "minimumTokensPerPhrase": 2,
            "salt": "regression-test",
        }

        for name, english, russian, expected_detail in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive_path = root / "corpus.zip"
                fixtures = root / "fixtures.jsonl"
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr("en.txt", english)
                    archive.writestr("ru.txt", russian)

                with mock.patch.object(gate, "ARCHIVE", archive_path), mock.patch.object(
                    gate, "FIXTURES", fixtures
                ):
                    with self.assertRaisesRegex(
                        ValueError,
                        rf"line count mismatch at line 2: {expected_detail}",
                    ):
                        gate.generate(manifest)


if __name__ == "__main__":
    unittest.main()
