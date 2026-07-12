# RuSwitcher Engineering Notes

This file is the repository-level operating context for future agents. Keep it
updated when architecture, behavior, model artifacts, tests, signing, or the
installed build changes.

## Product

- RuSwitcher is a local macOS menu-bar application for EN<->RU keyboard-layout
  conversion. The quality target is Caramba/Punto-like behavior without cloud
  inference or telemetry containing user text.
- Supported platform: macOS 13+; the release bundle is universal (`arm64` and
  `x86_64`).
- Automatic conversion is off by default until the user enables it.
- Primary repository: `rashn/RuSwitcher`; local branch used for this work:
  `codex/caramba-autoconvert`.
- As of 2026-07-12, the installed version is `4.0.0` build `73`. The latest
  committed baseline is `ec0c605` (`fix: make learned corrections global with
  app exceptions`); the build-73 punctuation/uppercase fix is pending commit.
- The installed app is `/Applications/RuSwitcher.app`, signed with the reusable
  identity `RuSwitcher Local Code Signing`.
- Installed build-73 executable SHA-256:
  `54e38c9ca18f8ea623839c93b5ddf2da01f5e7b9d3674e33e75815e1f652e8cb`.

## User Requirements

- Prefer reliable conversion over aggressive destructive edits. In ambiguous
  editor state, keep the text unchanged.
- Do not add word-specific hardcode for reported examples. Fix candidate,
  language-model, context, or transaction rules generically.
- The user prefers short progress/final messages in Russian.
- Do not use Computer Use for testing this app. Use unit tests, the simulator,
  and CGEvent/HID probes from the terminal.
- Do not replace the reusable signing identity with ad-hoc signing.
- Work with the existing worktree and never discard unrelated user changes.

## Package Layout

- `Sources/RuSwitcherCore`: pure/testable decoder, language models, candidate
  lattice, state and transaction data.
- `Sources/RuSwitcher`: AppKit application, event tap, layout switching, AX
  context, manual conversion, transaction execution and settings.
- `Sources/RuSwitcherSimulator`: parallel, non-HID corpus/phrase simulator.
- `Tests/RuSwitcherCoreTests`: unit, corpus, state-machine and transaction tests.
- `Tests/Fixtures/Simulator`: deterministic word and phrase fixtures.
- `Tests/Fixtures/HID/mixed-layout-corpus-batch.json`: continuous one-window
  CGEvent fixture selected from the user's 5,000-phrase corpus.
- `scripts`: model generation/training, corpus import, randomized simulation,
  isolated CGEvent tests and continuous batch tests.

SwiftPM targets:

- `RuSwitcherCore` library
- `RuSwitcher` executable
- `RuSwitcherSimulator` executable
- `RuSwitcherCoreTests`

## Decoder Architecture

The production decoder is a local noisy-channel decoder over physical keys. It
compares the literal-layout and opposite-layout hypotheses using:

- physical-key/lattice cost;
- frequent word probabilities;
- EN SCOWL and RU Hunspell spelling membership;
- character 2-5-gram plausibility;
- recent language belief and phrase context;
- compound analysis for unknown Russian forms;
- confirmed/manual pairs and adaptive counters;
- hard safety blockers.

Important types:

- `AutoConvertCandidate` and `AutoConvertCandidateGenerator`
- `PhysicalKeyLattice`
- `LayoutDecoder` (V3 production fallback/current decision engine)
- `ContextualLayoutDecoder` and `ContextualLayoutModel` (V4)
- `LanguageBelief`, `ContextSnapshot`, `CompoundWordAnalyzer`
- `InputSession`, `TokenSnapshot`, `ConversionTransaction`

V4 is a small local byte-level Core ML reranker over deterministic lattice
candidates. It never generates arbitrary text. The default mode is `shadow`, so
V3 remains authoritative while V4 decisions/latency are measured. Hidden modes:
`off`, `shadow`, `active` via `smartEngineV4Mode`.

V4 context is capped at 16 tokens and 192 UTF-8 bytes. A stale model result,
focus/revision mismatch, timeout, corrupt artifact, or unavailable model falls
back to V3/keep rather than performing a late edit.

## Candidate and Punctuation Rules

- Candidate generation preserves leading/trailing wrappers and explores the
  physical-key interpretation of punctuation keys.
- A single punctuation key that produces punctuation in both layouts follows
  the target physical-key interpretation when the word converts. This fixes an
  English-layout `?` intended as a Russian comma and `&` intended as a Russian
  question mark. Multi-mark suffixes such as `?!` and `...` remain literal.
- Typed punctuation remains literal when the opposite layout would turn it into
  a letter and the punctuation candidate is the valid word, as in `ghbdtn,`.
- Examples covered by tests:
  - `b` -> `и` in Russian context, but `plan B` stays unchanged.
  - `ghbdtncnde.` -> `приветствую` when the final physical period is Russian `ю`.
  - `ghbdtn, ` -> `привет, `.
  - `ghbitk? ` -> `пришел, `.
  - `ghbitk& ` -> `пришел? `.
  - `гыуб ` -> `use, `.
  - `афиду ` -> `fable `.
  - `дщщыут ` -> `loosen `.
  - `cegthcgbyf ` -> `суперспина `.
  - `htdjk.wbz ` -> `революция `.
- Automatic conversion now commits only on Space, Enter, or Tab. Punctuation is
  retained inside the token until that boundary. Do not restore conversion on
  the first punctuation key: it caused `...` to become `.//` after the layout
  switched mid-sequence and caused races with the following boundary.
- A word ending in punctuation with no following Space/Enter/Tab remains pending.

Hard blockers remain authoritative:

- secure input and password fields;
- denied applications (terminals, IDEs, password managers, etc.);
- URL, email and code/identifier shapes;
- mixed-script identifiers, camelCase and ALL-CAPS acronyms;
- single uppercase Latin letters;
- single uppercase Cyrillic letters;
- `neverConvert` rules;
- stale focus/revision/editor integrity.

Unknown valid Russian words must not convert to English from script score alone.
Both-known pairs such as `here`/`руку` use a strict safety threshold and normally
stay unchanged unless explicitly confirmed by the user.

## Event and Editing State

`KeyboardMonitor` and `InputSession` classify printable keys, Space/Enter/Tab,
Backspace, modified deletion, navigation, clipboard commands, Undo, focus changes
and synthetic events before mutating the token state.

- Plain Backspace removes one physical key.
- Option/Command+Backspace, forward Delete, Cut/Paste/Undo, arrows, mouse focus
  changes and tap recovery invalidate the token/revision as appropriate.
- Synthetic RuSwitcher events carry `kRuSwitcherEventMarker` and must never feed
  back into the state machine.
- Active taps use `.headInsertEventTap`; listen-only taps may use tail placement.
- Automatic replacement validates PID, bundle, focus identity, revision and the
  expected suffix before editing.

The reliable build-68 transaction path is intentional:

1. Consume the original Space only after the conversion decision succeeds.
2. Build ordered Backspace keyDown/keyUp events and one Unicode replacement.
3. Post the transaction directly to the validated target PID with
   `CGEvent.postToPid`, not into the shared global event stream.
4. Replay Space as one marked targeted key event.
5. Switch layout and update context/learning only after the transaction is accepted.

Do not revert this to a burst through `tapPostEvent` or a Unicode payload ending
in a space. Continuous CGEvent tests demonstrated lost Backspaces, missing spaces,
duplicate spaces and duplicated first characters with those approaches.

## Manual Trigger and Learning

The configured trigger is currently used as double Shift by the user. Priority:

1. Convert a real non-empty selection.
2. Convert the current buffered token.
3. Undo/reconvert the immediately preceding automatic correction.
4. Switch layout only.

Selection direction is based on dominant script, not the active layout. AX
selected-text replacement is preferred; clipboard fallback preserves pasteboard
types. Failure must leave selection and layout unchanged.

Adaptive learning behavior:

- A successful manual word conversion records a normalized, globally confirmed
  source/target pair. The next occurrence can auto-convert without dictionary
  evidence.
- A completed following token is a weak positive signal.
- immediate Undo or Backspace is a negative signal and removes confirmation;
  it does not automatically create a permanent `neverConvert` rule.
- Simple switch-only actions do not train.
- Rules and the V4 personalization adapter persist in `UserDefaults`.
- Advanced settings can reset learned corrections.
- Advanced settings can export and import learned word rules as a versioned,
  human-readable JSON archive. Import merges by normalized source, target and
  app scope; it is idempotent, preserves confirmations and keeps the larger
  counters/newer timestamp. The archive contains adaptive pairs/counters only,
  never typed context, general settings, always/never lists or adapter weights.
- Archive validation is atomic: reject foreign/unsupported formats, files over
  5 MB, more than 2,000 rules and invalid fields without changing current rules.

## Models and Provenance

Bundled resources:

- `language-model-v1.bin`: versioned V3 model, current SHA-256
  `954cd3d86fae11dc6e82d099996406a4259c7f1148f67fbfa5d445ef45deb347`.
- `layout-model-v4.json` and `LayoutRerankerV4.mlmodelc`: bootstrap V4 shadow
  artifact and manifest.

`scripts/build_language_model.py` reproducibly builds the V3 artifact. Inputs and
hashes are pinned in `scripts/v4_training_sources.json`:

- Google Books frequency data, CC BY 3.0.
- English Speller Database/SCOWL level 60, revision/tag pinned in the manifest.
- LibreOffice Russian Hunspell dictionary revision
  `38d96a4d54ec3449cf7f28cddae1fce32e2b15a7`.
- The Russian dictionary expands lowercase forms with one SFX rule and stores
  roughly 1.42 million forms in a 2^25-bit, 9-hash Bloom filter.

Keep `THIRD_PARTY_NOTICES.md`, source archives under `scripts/data`, manifest
hashes and `build_app.sh` resource copying synchronized. The app performs no model
downloads and no network inference.

## Privacy and Statistics

- Decoder, models and personal learning are local.
- Debug logs contain only lengths, language/evidence categories, revision,
  latency buckets and transaction outcomes; never words or neighboring text.
- Anonymous statistics are opt-in and contain aggregate outcomes/buckets only,
  never text or app IDs.
- Debug logging was disabled and the temporary debug log removed after build-68
  verification; build 70 preserves the user's existing logging preference.

## Test Corpus and Current Results

User-provided external files (not committed):

- `/Users/bezh/Downloads/mixed_word_layout_stress_test_5000.txt`
- `/Users/bezh/Downloads/mixed_word_layout_stress_test_pairs_5000.tsv`

The TSV has 5,000 phrases and 59,388 labelled tokens. Import/run with:

```bash
python3 scripts/run_mixed_layout_tsv_suite.py \
  /Users/bezh/Downloads/mixed_word_layout_stress_test_pairs_5000.tsv
```

Last audited result:

- 58,718 / 59,388 tokens correct: 98.8718%.
- 4,371 / 5,000 phrases entirely exact.
- 100% keep accuracy for correct English, correct Russian and technical tokens.
- 670 remaining failures were safe misses; zero wrong replacements/false positives.
- Reports are generated under `.build/mixed-layout-5000-*.json*`.

Pure and deterministic checks:

```bash
swift test
swift run -c release RuSwitcherSimulator --output .build/simulator-final-report.json
bash scripts/run_randomized_layout_suite.sh
bash scripts/verify_simulator_negative_control.sh
```

Last results: 161/161 unit tests, 11,128/11,128 built-in simulator checks,
38/38 randomized checks, and a passing intentional negative control.

Learned-rule persistence is tested by `scripts/run_manual_learning_test.sh`: an
unknown pair stays unchanged before training, selected-text double Shift creates
a confirmation, the next physical-key input converts, and the conversion still
works after restarting RuSwitcher. The script restores the complete preferences
domain afterward, so it does not pollute the user's dictionary.

Real CGEvent tests, without Computer Use:

```bash
bash scripts/run_hid_integration_tests.sh
bash scripts/run_hid_batch_tests.sh
```

- Isolated suite: 18/18 scenarios.
- Continuous batch: 19 phases and 160 physical characters in one `NSTextView`,
  selected from corpus IDs `mixed-layout-00653`, `mixed-layout-00926` and
  `mixed-layout-02466`.
- After the final transaction fix it passed five consecutive/final runs exactly,
  including quotes, wrappers, `?!`, `...`, an email, mixed RU/EN and double spaces.
- Keep isolated tests for pinpoint diagnostics and the continuous test for stale
  state, punctuation damage, missed Backspaces and duplicate insertion.
- Do not run multiple CGEvent UI probes in parallel: macOS has one focus/layout
  event stream. The pure simulator may use parallel workers.
- `Tests/Fixtures/HID/punctuation-and-uppercase-regression.json` covers the
  build-73 punctuation and uppercase regressions in one continuous window. Its
  2026-07-12 run was inconclusive because the probe process lacked Accessibility
  event-posting access (`postEventAccess=false`, `focus-unavailable`); do not
  report it as passed until that host permission is restored.

## Build, Signing and Installation

Before installation:

```bash
swift test
git diff --check
SIGN_ID='RuSwitcher Local Code Signing' bash build_app.sh
codesign --verify --deep --strict RuSwitcher.app
lipo -archs RuSwitcher.app/Contents/MacOS/RuSwitcher
```

`build_app.sh` stamps `version.json`, builds universal, copies model/licence
resources and signs the bundle. Increment the build number for every installed
binary change.

Install atomically:

1. Copy the built bundle to a unique staging path under `/Applications`.
2. Verify the staged signature.
3. Stop the running `RuSwitcher` process.
4. Move the current app to a timestamped backup.
5. Move staging to `/Applications/RuSwitcher.app`.
6. Open the app and verify version, architectures, signature, SHA-256 and process.

Current observed footprint for build 68:

- App bundle: about 14.4 MiB on disk.
- V3 language model: 7,296,305 bytes.
- Idle process: approximately 0-0.1% CPU and 81 MiB RSS on the development Mac.
- Decoder inference in the simulator: under roughly 4 ms p99 per completed token.

The installed binary SHA-256 after build 68 was
`bfe6ad8d011efc1e6408fb35f4b325673316f485453b0620b2b37d1fe8898b50`.
Always compare installed and freshly built hashes rather than trusting the build
number alone.
