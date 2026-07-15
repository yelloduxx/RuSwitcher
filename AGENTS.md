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
- Primary repository: `yelloduxx/RuSwitcher`; the production branch is `main`.
  `rashn/RuSwitcher` is the author's upstream repository, not a release source
  for this fork.
- Codex Lab on `main` is `4.0.0` build `105` (`RuSwitcher Lab.app`,
  `com.ruswitcher.lab`, SHA-256
  `503e07d18caeb3bbaf722c52e6b7a85e0bd9bf086e42cdb5759d802d7ea6ac33`).
  Do not overwrite Lab from this worktree.
- This Grok branch (`grok/ruswitcher-ax`) adopts Lab **105 conversion logic**
  and ships competitive **RuSwitcher AX** build **107**:
  - Bundle: `RuSwitcherAX.app` → `/Applications/RuSwitcherAX.app`
  - Bundle ID: `com.ruswitcher.ax` · Executable: `RuSwitcherAX` · Dev tag: `ax`
  - Logs: `~/Library/Logs/RuSwitcherAX/ruswitcher-ax.log` via
    `ProductIdentity.logFilePath` (Settings and rslog must match)
  - Beyond Lab: fixed Settings log path, ProductIdentity branding, caret-word
    busy retry gated on focus/sequence/revision, live sibling health check,
    no `allowUnavailablePreflight` (unavailable AX always blocks auto post),
    AX-default test scripts
- The author's original app remains `/Applications/RuSwitcher.app` (`2.7.0`
  build `35`). Never overwrite Lab or author from this branch.
- Verify the installed binary hash and PID after every local replacement; do
  not infer the running build from `version.json` alone.
- `claude/generic-ax-fallback` is a separate worktree
  (`/Users/bezh/Documents/ruswitch-claude`) branched from build **108**
  (`a4f72f4`), before `grok/ruswitcher-ax` continued past it into
  Ghostty-specific System Events/Automation/Ctrl+W special-casing (commits
  109-115). It replaces `ManualHostPolicy`'s hardcoded bundle-ID allowlist
  (`com.mitchellh.ghostty`, `com.openai.codex`) with runtime capability
  detection: any host whose `kAXSelectedTextAttribute` write is confirmed to
  insert-instead-of-replace is learned (process-lifetime only) after
  `recoverInsertedReplacement` proves it; any host where AX cannot be read at
  all (`.unavailable` — most terminal emulators, unregistered in any list)
  falls through to Backspace+Unicode on every attempt, gated by a fresh
  `isCurrent()`/frontmost recheck immediately before posting instead of by
  bundle identity. No app-specific code is required for a new broken host.
  Ships as its own parallel-comparison product, **RuSwitcher Claude**:
  - Bundle: `RuSwitcherClaude.app` → `/Applications/RuSwitcherClaude.app`
  - Bundle ID: `com.ruswitcher.claude` · Executable: `RuSwitcherClaude` ·
    Dev tag: `claude` (shown as `4.0.0claude (108)` in menu/settings)
  - Logs: `~/Library/Logs/RuSwitcherClaude/ruswitcher-claude.log`
  - Signed with the reusable `RuSwitcher Local Code Signing` identity.
  - Installed executable SHA-256:
    `e514190342840ee8f4faa766de74c41b566e8499376628a44338ed398fa93c06`.
  - Runs alongside Lab/AX/author/Codex without colliding (separate
    Accessibility/Input Monitoring grant, separate defaults domain, separate
    login item); never overwrites any of them.

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

- `Sources/RuSwitcherCore`: pure/testable V3 decoder, language model, state and
  transaction data.
- `Sources/RuSwitcherAppSupport`: testable native replacement, event,
  pasteboard, logging and release-version contracts.
- `Experimental/V4`: separate Swift package for the Core ML research project;
  it is absent from the root package graph and production bundle.
- `Sources/RuSwitcher`: AppKit application, event tap, layout switching, AX
  context, manual conversion, transaction execution and settings.
- `Sources/RuSwitcherSimulator`: parallel V3 corpus/phrase simulator.
- `Sources/RuSwitcherTypingSimulator`: headless physical-event simulator over
  `InputSession`, V3 and replacement transaction plans. It supports one
  continuous fixture or independent phrase JSONL batches via `--jobs`.
- `Tests/RuSwitcherCoreTests`: unit, corpus, state-machine and transaction tests.
- `Tests/RuSwitcherAppSupportTests`: native-contract tests with controlled fakes.
- `Experimental/V4/Tests`: isolated V4 research tests.
- `Tests/Fixtures/Simulator`: deterministic word and phrase fixtures.
- `Tests/Fixtures/HID/mixed-layout-corpus-batch.json`: continuous one-window
  CGEvent fixture selected from the user's 5,000-phrase corpus.
- `scripts`: model generation/training, corpus import, randomized simulation,
  isolated CGEvent tests and continuous batch tests.

SwiftPM targets:

- `RuSwitcherCore` library (production V3)
- `RuSwitcherAppSupport` library
- `RuSwitcher` executable
- `RuSwitcherSimulator` executable
- `RuSwitcherTypingSimulator` executable
- `RuSwitcherCoreTests`
- `RuSwitcherAppSupportTests`

V4 has its own package and is built only with
`swift test --package-path Experimental/V4`.

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
- `LayoutDecoder` (the sole production decision engine)
- `LanguageBelief`, `CompoundWordAnalyzer`
- `InputSession`, `TokenSnapshot`, `ConversionTransaction`
- `ReplacementCoordinator`, `InputEventClassifier` and
  `KeyboardLayoutTranslationState`

V4 is not part of the application runtime, settings, root simulator or app
resources. Its Core ML model, lattice, adapter and decoder live only in the
separate `Experimental/V4` package. For EN/RU, a missing V3 model causes a safe
keep; it never activates another automatic decoder.

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
- Physical key code alone is not a boundary. `KeyboardLayoutTranslationState`
  keeps the Carbon dead-key state for the active input source. On US
  International-PC, quote followed by physical Space produces a quote and must
  remain inside the token; only a translated literal space is a word boundary.
- AX suffix validation retries one mismatch after 0.75 ms within the existing
  4 ms deadline. This handles short-token races in WebKit/Electron while still
  blocking a persistent focus/caret mismatch.
- Posted replacement events are verified asynchronously for up to 120 ms. This
  does not block the event callback; it prevents a temporarily stale AX value
  from clearing valid phrase context after the editor has accepted a conversion.

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
  expected suffix before editing. An unavailable AX preflight blocks the post;
  a timed-out field is retried after a one-second cooldown rather than being
  ignored for 30 seconds.
- A posted conversion immediately publishes provisional phrase context for the
  next token. AX read-back confirms learning and Undo state without duplicating
  that context; stale verification never overrides newer input. An unavailable
  or mismatching read-back invalidates the provisional state and does not switch
  the layout.

The reliable build-68 transaction path is intentional:

1. Consume the original Space only after the conversion decision succeeds.
2. Build ordered Backspace keyDown/keyUp events and one Unicode replacement.
3. Post the transaction directly to the validated target PID with
   `CGEvent.postToPid`, not into the shared global event stream.
4. Replay Space as one marked targeted key event.
5. Switch layout and create learning/Undo state only after verified AX read-back.

Do not revert this to a burst through `tapPostEvent` or a Unicode payload ending
in a space. Continuous CGEvent tests demonstrated lost Backspaces, missing spaces,
duplicate spaces and duplicated first characters with those approaches.

## Manual Trigger and Learning

The configured trigger is currently used as double Shift by the user. Priority:

1. Convert a real non-empty selection.
2. Convert the current buffered token.
3. Convert the last completed buffered token after a boundary.
4. Recover and convert the exact token before the caret through verified AX when
   navigation or focus changes have invalidated the physical-key buffer.
5. Undo/reconvert the immediately preceding automatic correction.
6. Switch layout only.

Selection direction is based on dominant script, not the active layout. AX
selected-text replacement is preferred. Clipboard fallback is retained only
when the selected text itself cannot be read; it preserves pasteboard types.
Failure must leave selection and layout unchanged.

Accessibility is the primary path for current-token, previous-token and selected
text conversion. When AX cannot expose a known current/previous suffix, the
fallback selects its grapheme count with targeted Shift+Left events and posts
the replacement as targeted Unicode. This path does not touch the pasteboard,
does not post Backspace and cannot delete the word if insertion is dropped.

Manual current/previous-word conversion is a forced physical-layout toggle; it
does not ask the decoder whether either spelling is correct. It replaces the
exact suffix before the caret atomically through Accessibility when available.
The non-AX fallback never posts Backspace. A read-back verified edit may learn;
a fallback edit is
`postedUnverified` and never learns. Repeated double Shift toggles the remembered
pair, also immediately after an automatic conversion.

For an in-process `NSTextView` host, selected-text AX mutation must run on the
main thread. Calling `AXUIElementSetAttributeValue` for a local AppKit element
from the manual AX queue triggers AppKit's queue assertion and crashes. External
AX mutation remains asynchronous and polls bounded read-back before fallback.

Adaptive learning behavior:

- A successful manual word conversion records a normalized, globally confirmed
  source/target pair. The next occurrence can auto-convert without dictionary
  evidence.
- A completed following token is a weak positive signal.
- Explicit Undo or double-Shift reversal is a negative signal. A plain first
  Backspace after auto-conversion usually deletes the replayed space and must not
  train or create an application exception.
- A permanent application exception is created only when explicitly reversing a
  globally confirmed manual pair. Weak automatic positives are not sufficient.
- Rule-book model 8 removes legacy app-local negative rules and unsafe learned
  pairs. Persistent manual pairs require at least two letters on both sides, so
  accidental `а`/`f` or `b`/`и` confirmations cannot become global overrides.
- Simple switch-only actions do not train.
- Adaptive rules persist in `UserDefaults`.
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
- Production `.app` contains no V4 model. `layout-model-v4.json` and
  `LayoutRerankerV4.mlmodelc` belong only to `Experimental/V4`.

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

## Privacy

- Decoder, models and personal learning are local.
- Debug logs contain only lengths, language/evidence categories, revision,
  latency buckets and transaction outcomes; never words or neighboring text.
- The anonymous-statistics UI, reporter, persistence and localization keys were
  removed. There is no statistics endpoint.
- `rslog` accepts only `StaticString`; dynamic user text, context, paths, layout
  IDs, bundle IDs and localized errors cannot be passed to it.

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

- 58,945 / 59,388 tokens correct: 99.2541%.
- 4,577 / 5,000 phrases entirely exact.
- 100% keep accuracy for correct English, correct Russian and technical tokens.
- 443 remaining failures were safe misses; zero wrong replacements/false positives.
- Reports are generated under `.build/mixed-layout-5000-*.json*`.

Pure and deterministic checks:

```bash
swift test
swift run -c release RuSwitcherSimulator --output .build/simulator-final-report.json
bash scripts/run_randomized_layout_suite.sh
bash scripts/verify_simulator_negative_control.sh
bash scripts/run_headless_typing_simulator.sh
python3 scripts/run_mixed_layout_event_stream_suite.py \
  /Users/bezh/Downloads/mixed_word_layout_stress_test_pairs_5000.tsv --jobs 8
bash scripts/run_headless_native_parity_test.sh
bash scripts/verify_v3_only_build.sh
```

After removing V2, the root suite contains 171 tests. V4's 12 research tests run
only from its separate package. The headless event-stream fixture must pass and
its intentionally wrong expected output must fail.

The 443 safe misses in the 5,000-phrase corpus are six repeated ambiguous
lexical bases: `где` 157, `next` 95, `I` 77, `буфер` 60, `я` 41 and `he` 13.
They are abstentions, not wrong replacements.

The full headless event-stream corpus mode keeps every phrase sequential and
isolated while scheduling separate phrases in parallel. On the development Mac,
the same 59,388-token corpus took 9.902 s with 1 worker, 4.456 s with 3 workers
and 2.370 s with 8 workers. All three 5,000-line result files were byte-identical
(`ec58b110663e37650f5025deb151fc05fb30dcbafed2b23f88f4e9b2d8aed6`):
58,945 correct tokens, 443 safe misses, zero false/wrong replacements and zero
duplicate transactions. The batch quality gate rejects any false replacement,
wrong replacement, duplicate transaction or regression above 443 safe misses.

Learned-rule persistence is tested by `scripts/run_manual_learning_test.sh`: an
unknown pair stays unchanged before training, selected-text double Shift creates
a confirmation, buffered-token double Shift converts the unfinished word in the
phrase `сегодня я ...`, and previous-token double Shift converts the last word
after a Space. The probes assert a zero pasteboard `changeCount` delta for all
three manual paths. The next physical-key input converts, and the conversion
still works after restarting RuSwitcher. Each native probe runs alone so two
global event taps cannot process the same trigger. The script restores the
complete preferences domain afterward, so it does not pollute the user's
dictionary.

Forced manual toggle cycles are tested by
`scripts/run_manual_toggle_cycle_test.sh`. The short native CGEvent probe covers
the current Cyrillic token, a real selection, an immediately auto-converted
previous word and a token recovered before the caret after navigation. It
asserts the exact text after every double Shift, preserves two spaces in the
caret scenario and requires a zero pasteboard `changeCount` delta. The
Cyrillic-token scenario forces targeted synthetic-input fallback so the non-AX
editor path remains covered. The probe also records every observed layout and
fails unless both and only the configured RU/EN layouts are used; isolated
defaults can never auto-select a Chinese IME.

Real CGEvent tests, without Computer Use:

```bash
bash scripts/run_hid_batch_tests.sh
bash scripts/run_hid_stress_tests.sh
```

- The authored stress fixture contains 16 natural mixed-language phrases, 164
  alternating-layout phases and 939 physical input characters in one
  `NSTextView`, without pauses after words.
- It passed exactly after the stateful dead-key and asynchronous AX verification
  fixes, including straight/double quotes under US International-PC, wrappers,
  `?!`, `...`, `@`, email, `plan B`, one-letter conjunctions and alternating
  RU/EN words.
- Do not run multiple CGEvent UI probes in parallel: macOS has one focus/layout
  event stream. The pure simulator may use parallel workers.
- `headless-native-parity-trap.json` is shared by the headless simulator and the
  native host. Its 13 phases and 121 physical characters cover both-known
  context, short words, dead-key quotes, punctuation/layout-letter ambiguity,
  email, `plan B`, double spaces and a rare Russian word. Build 88 produced the
  same exact text in both paths: 9 planned headless transactions and 9/9 native
  posted/verified transactions, with no external input, layout mismatch or
  boundary timeout. The native host disables macOS double-space period and
  automatic capitalization only through a volatile test-process defaults domain.
- The headless typing simulator opens no window and does not touch the global
  event stream. It validates production state and transaction planning, but not
  macOS CGEvent/AX delivery; that final layer requires an isolated user session,
  VM or the visible native host.
- HID probes use the isolated `com.ruswitcher.hidhost` preferences suite, reset
  at probe startup, so corpus runs cannot train or mutate the user's learned
  rules. The manual persistence script opts into the standard domain explicitly,
  backs it up and restores it on exit.

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
5. Move staging to `/Applications/RuSwitcherAX.app`; do not overwrite the
   author's `/Applications/RuSwitcher.app` or Codex
   `/Applications/RuSwitcher Lab.app`.
6. Open the app and verify version, architectures, signature, SHA-256 and process.

Lab 105 footprint (Codex reference): ~10.84 MiB bundle, ~77.5 MiB idle RSS,
model 7,296,305 bytes. AX build 106 hash is recorded after install.
Always compare installed and freshly built hashes rather than trusting the build
number alone.
