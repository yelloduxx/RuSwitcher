#!/bin/bash
set -euo pipefail

BIN="/Applications/RuSwitcher.app/Contents/MacOS/RuSwitcher"
test -x "$BIN"
pgrep -f '/Applications/RuSwitcher.app/Contents/MacOS/RuSwitcher' >/dev/null || open /Applications/RuSwitcher.app

python3 - "$BIN" "$@" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
import time

binary = sys.argv[1]
requested = set(sys.argv[2:])
expected = {
    "use-comma": "use, ",
    "use-comma-no-boundary": "use,",
    "use-comma-after-russian": "план use,",
    "revolution": "революция ",
    "privetulki": "приветульки ",
    "hello-from-russian": "hello ",
    "use-comma-from-russian": "use, ",
    "fable-from-russian": "fable ",
    "wipe-from-english": "протереть ",
    "butt-from-english": "задница ",
    "slur-from-english": "пидр ",
    "cyst-stays-english": "cyst ",
    "juju-stays-english": "juju ",
    "codex-stays-english": "codex ",
    "loosen-from-russian": "loosen ",
    "hello-comma-from-russian": "hello, ",
    "world-period-from-russian": "world. ",
    "privet-period-from-english": "привет. ",
}
if requested:
    unknown = requested.difference(expected)
    if unknown:
        raise SystemExit(f"unknown scenarios: {', '.join(sorted(unknown))}")
    expected = {name: value for name, value in expected.items() if name in requested}
repeats = max(1, int(os.environ.get("RUSWITCH_HID_REPEATS", "1")))

failed = False
for attempt in range(1, repeats + 1):
  for scenario, wanted in expected.items():
    result_path = os.path.join(tempfile.gettempdir(), f"ruswitch-hid-{os.getpid()}-{scenario}.json")
    try:
        os.unlink(result_path)
    except FileNotFoundError:
        pass
    process = subprocess.run([
        "open", "-n", "/Applications/RuSwitcher.app", "--args",
        "--hid-probe", scenario, "--result", result_path,
    ], text=True, capture_output=True, timeout=5)
    if process.returncode != 0:
        print(f"FAIL {scenario}: launch exit={process.returncode} stderr={process.stderr.strip()}")
        failed = True
        continue
    deadline = time.monotonic() + 8
    while not os.path.exists(result_path) and time.monotonic() < deadline:
        time.sleep(0.1)
    if not os.path.exists(result_path):
        print(f"FAIL {scenario}: no result file")
        failed = True
        continue
    try:
        with open(result_path, encoding="utf-8") as handle:
            result = json.load(handle)
    except Exception as error:
        print(f"FAIL {scenario}: invalid result: {error}")
        failed = True
        continue
    finally:
        try:
            os.unlink(result_path)
        except FileNotFoundError:
            pass
    okay = result["postEventAccess"] and result["text"] == wanted
    label = f"{scenario} [{attempt}/{repeats}]" if repeats > 1 else scenario
    print(f"{'PASS' if okay else 'FAIL'} {label}: {result['text']!r} access={result['postEventAccess']}")
    failed |= not okay
    time.sleep(0.5)

raise SystemExit(1 if failed else 0)
PY
