# RuSwitcher

<p align="center">
  <img src="icon.png" width="128" alt="RuSwitcher icon">
</p>

<p align="center">
  <b>Lightweight keyboard layout switcher for macOS</b><br>
  Free and open-source alternative to PuntoSwitcher
</p>

<p align="center">
  <a href="https://github.com/rashn/RuSwitcher/releases/latest"><img src="https://img.shields.io/github/v/release/rashn/RuSwitcher?style=flat-square" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/rashn/RuSwitcher?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=flat-square" alt="Swift 6">
</p>

<p align="center">
  <a href="#english">English</a> · <a href="#русский">Русский</a>
</p>

---

## English

Typed `ghbdtn` when you meant `привет`? Just tap **Option ⌥** and RuSwitcher converts the last word into the right layout — typing it directly, no copy-paste. Works with any pair of installed keyboard layouts — Russian, Ukrainian, Belarusian, German, French, and more. The trigger is fully configurable (a single key or a two-key combo), it can also fix the layout **automatically as you type**, and it even works through **Apple Screen Sharing**.

### How it works

| Action | Result |
|---|---|
| Type a word, tap **Option ⌥** | Last typed word is converted |
| Tap **Option ⌥** again | Reverse conversion (undo) |
| Select text, tap **Option ⌥** | Selected text is converted |

The trigger is configurable — **Option**, **Command**, **Control** or **Shift** (left or right side, single or double-tap), or a **two-key combo** (⌘+⇧, ⌃+⇧, ⌘+⌥, ⌃+⌥) for the Windows-style Alt+Shift feel.

### Automatic conversion

RuSwitcher can also fix the layout **automatically as you type**, with no key press. Turn it on in **Settings → Auto-conversion** (off by default). Smart Engine V4 adds a compact local byte-level Transformer over a physical-key lattice to the V3 noisy-channel decoder. It sees up to 16 recent tokens, ranks only deterministic layout/punctuation candidates and can abstain. Inference is prefetched after the last letter; the boundary callback uses it only when sequence, revision and focus still match, otherwise it immediately falls back to V3. V4 initially runs in shadow mode so it can be measured without changing text.

It handles common short words (`b` → `и`, `z` → `я`), long words such as `ghbdtncnde.` → `приветствую`, trailing punctuation (`ghbdtn,` → `привет,`) and unknown compounds such as `cegthcgbyf` → `суперспина` (`супер` + `спина`). Corrections happen only after Space, Enter or Tab, never halfway through a word; punctuation remains part of the token until that boundary so repeated marks cannot be corrupted by a mid-sequence layout switch. To avoid dangerous false fixes it skips words with digits / URLs / email-like text, single uppercase Latin letters (`plan B`), ALL-CAPS acronyms, camelCase / mixed-script code identifiers, terminals / IDEs / password managers, and password fields.

For Latin input, an English-first source gate protects frequent words and a separate 80,000+ form ESDB/SCOWL spelling lexicon before considering RU conversion. Words outside both dictionaries are classified by English character probability: plausible English OOV forms get a keep bias, while English-unlikely physical-key strings may switch when the Russian hypothesis has stronger lexical, character or contextual evidence. For RU→EN, the same spelling lexicon confirms a target only when the Cyrillic source is unknown, the word has at least four letters and the English character model wins by a calibrated margin.

Russian spelling evidence uses an offline-expanded LibreOffice Hunspell dictionary represented by a compact 4 MB Bloom filter with more than one million inflected forms. It confirms words such as verb imperatives without adding per-word exceptions and protects valid Russian source forms. When both physical interpretations are real words (`туче`/`next`), RuSwitcher keeps the literal text unless explicit learning provides stronger evidence.

The input state is revision-based: Backspace updates the current physical token, while word deletion, navigation, Cut/Paste/Undo, mouse clicks and focus changes invalidate stale state. Before an automatic replacement RuSwitcher performs a read-only Accessibility check when the target supports it, then posts one ordered replacement transaction. This prevents stale selection, duplicate insertion and deletion at the wrong caret.

Undoing an automatic correction or immediately editing it teaches RuSwitcher locally. V4 stores only a small 192-value personalization adapter and counters, never the typed context; manually converted pairs remain explicit local confirmations. Learned word pairs and their counters can be exported to a versioned JSON backup and merged back through **Settings → Advanced**. Reimporting the same file is safe and does not duplicate rules. Learned state can also be reset there. The explicit **Always convert** and **Never convert** lists remain hard overrides.

**Three exception lists** let you tune it (Settings → Auto-conversion):
- **Apps** — where auto-conversion stays off (terminals, IDEs and password managers are pre-filled; password managers can't be removed).
- **Never convert** — words it must never touch (nicknames, logins, brands). After a wrong fix, tap the trigger to undo and RuSwitcher offers to add the word here.
- **Always convert** — words to always fix even if they aren't in the dictionary (compound words, slang). Add the **target** word — the result you want.

### Remote desktop (beta — new in 2.5)

RuSwitcher works through **Apple Screen Sharing**. Type into a remote Mac's session and fix wrong-layout text right there — by trigger or automatically — just like on your local machine. Run RuSwitcher on **both** Macs and turn on **Remote Desktop mode** (beta, marked in the menu). Conversion happens on the Mac you're controlling, where the text actually lives.

### Layout flag at the cursor (beta — new in 2.6)

After you switch layout, RuSwitcher can briefly show the layout flag **right next to the text cursor** — so you see which layout you're in without glancing at the menu bar. It hides as you start typing. Turn it on in the menu or Settings (off by default). It works wherever the app exposes the cursor position via Accessibility (native apps and most text fields); a few apps that draw their own text (e.g. the VS Code editor) don't expose it — there macOS's own input indicator covers the gap.

### Features

- **Any two layouts** — configure any pair from your installed system layouts. No hardcoded tables.
- **Switch layout from the menu** *(new in 2.6.1)* — pick any installed layout right from the menu-bar menu (flag, name, a check on the current one) and click to switch.
- **Configurable trigger** — Option, Command, Control or Shift (left/right, single/double-tap), or a two-key combo like ⌘+⇧.
- **Automatic conversion** — optionally fix the layout as you type, including common short words and trailing punctuation. Off by default.
- **Remote desktop (beta)** — fix the layout over Apple Screen Sharing, on the Mac you're controlling.
- **Exception lists** — a per-app exclusion list plus never-convert and always-convert word lists.
- **Layout sound (optional)** — a short sound on the first letter after a layout change, so you *hear* which layout you're in.
- **Layout flag at the cursor (beta)** — briefly show the layout flag next to the text cursor right after a switch.
- **Monochrome menu-bar icon (optional)** *(new in 2.6.1)* — a system-style `РУ/EN` badge instead of the colored flag; adapts to light/dark automatically. Off by default.
- **Universal binary** — runs natively on both Apple Silicon and Intel Macs.
- **Clipboard-free** — the converted word is typed directly via synthesized Unicode, so it works even in Electron / VS Code / Atom-class editors. Your clipboard is never touched (it's only a fallback for unusual apps).
- **Smart word detection** — converts the last typed word, including punctuation.
- **Selected text** — select any text and tap the trigger to convert it in place.
- **Tap again to undo** — reverse conversion if you changed your mind.
- **Per-app layout memory** — remembers the active layout for each application and restores it when you switch back.
- **16 interface languages** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português, Polski, 中文, 日本語, 한국어, Ελληνικά, Български, Հայերեն, ქართული.
- **Auto-start at login** — set and forget.
- **Minimal footprint** — no Electron, no web views, pure Swift + AppKit.
- **Private by default** — anonymous quality statistics are opt-in and never contain words, nearby text, or app names.

### Installation

**Homebrew (recommended)**

```bash
brew tap rashn/ruswitcher
brew install --cask ruswitcher
```

To upgrade later: `brew upgrade --cask ruswitcher`.

**Download DMG**

Grab the latest `.dmg` from [**Releases**](https://github.com/rashn/RuSwitcher/releases/latest), open it and drag RuSwitcher to Applications.

**Build from source**

```bash
git clone https://github.com/rashn/RuSwitcher.git
cd RuSwitcher
bash build_app.sh
cp -R RuSwitcher.app /Applications/
```

Requires macOS 13+ and Xcode Command Line Tools.

### Permissions

On first launch, RuSwitcher requests two macOS permissions:

1. **Accessibility** — to read and modify text in applications.
2. **Input Monitoring** — to detect keyboard events.

The app adds itself to the permission lists automatically — you only need to flip the toggles. The built-in permission wizard walks you through it step by step.

### Technical details

- An active `CGEventTap` for ordered automatic replacement; synthetic events are marked and ignored by the state machine.
- `UCKeyTranslate` (Carbon) for dynamic character mapping between any layout pair.
- `CGEvent.keyboardSetUnicodeString` to type the converted text directly — no clipboard, no pasteboard side effects.
- `CGEventSource.userData` marker to filter the app's own simulated events.
- A memory-mapped, versioned local RU/EN language model generated from pinned Google Books n-gram frequency data.
- A checksum-verified FP16 Core ML byte Transformer that only reranks candidates from a deterministic physical-key lattice.
- Read-only `AXUIElement` range probes for focus and suffix validation; selected-text conversion uses AX first and preserves every pasteboard type in its fallback.
- `SMAppService` for login item management.
- No hardcoded layout tables — works with any installed layouts.

### Simulation and quality testing

`RuSwitcherSimulator` runs the real decoder against generated or JSONL fixtures in parallel, without Accessibility permissions or keyboard emulation:

```bash
swift run -c release RuSwitcherSimulator --engine v4-shadow --jobs 8 --output simulation.json
```

Use `--engine v3|v4-shadow|v4-active` to compare engines. The JSON report includes V4 outcomes, disagreement count and latency percentiles. `--input fixtures.jsonl` accepts custom words, `--phrase-input phrases.jsonl` accepts stateful mixed-language phrases, and `--phrase-results results.jsonl` writes a complete step trace. Pure decoder simulations need no HID. `scripts/run_hid_integration_tests.sh` isolates individual event-tap cases; `scripts/run_hid_batch_tests.sh` types mixed corpus fragments continuously in one window to catch stale state, punctuation damage and duplicate insertion.

Anonymous quality reporting is off by default. It stores only aggregate outcome/reason/length buckets. Upload is enabled only in builds that define `RSStatisticsEndpoint`; no endpoint means no network request.

### Settings

Access via the menu bar icon → **Settings** (⌘,).

- **General** — conversion trigger (single key or combo), per-app layout memory, launch at login, interface language, layout pair.
- **Auto-conversion** — automatic conversion, **Remote Desktop mode (beta)**, and the three exception lists (apps, never-convert, always-convert).
- **About** — version, donate, contact, check updates.
- **Advanced** — Smart Engine/model version, learned-word export/import/reset, debug logging and log management.

The menu-bar menu also has quick toggles for Automatic conversion, Layout sound, Flag at cursor and Remote Desktop mode.

### Support the project

If you find RuSwitcher useful:

- [**Boosty**](https://boosty.to/ruswitcher) — donate
- **Star** this repo on GitHub

### License

[MIT](LICENSE) — free to use, modify, and distribute.

---

## Русский

Набрали `ghbdtn` вместо `привет`? Просто нажмите **Option ⌥** — и RuSwitcher сконвертирует последнее слово в правильную раскладку, печатая его напрямую, без копипасты. Работает с любой парой установленных раскладок — русская, украинская, белорусская, немецкая, французская и другие. Триггер настраивается (одна клавиша или комбо из двух), есть **автоматическая конверсия по ходу набора**, и всё это работает даже через **Apple Screen Sharing**.

### Как работает

| Действие | Результат |
|---|---|
| Набрать слово, нажать **Option ⌥** | Последнее слово сконвертировано |
| Нажать **Option ⌥** повторно | Обратная конвертация (отмена) |
| Выделить текст, нажать **Option ⌥** | Выделенный текст сконвертирован |

Триггер настраивается — **Option**, **Command**, **Control** или **Shift** (левый или правый, одиночный или двойной тап), либо **комбо из двух клавиш** (⌘+⇧, ⌃+⇧, ⌘+⌥, ⌃+⌥) — в стиле привычного Alt+Shift.

### Автоматическая конверсия

RuSwitcher умеет исправлять раскладку **автоматически по ходу набора**, без нажатий. Включается в **Настройки → Автоконверсия** (по умолчанию выключено). Smart Engine V4 добавляет к noisy-channel decoder компактный локальный byte-level Transformer и lattice физических клавиш. Он видит до 16 последних токенов, ранжирует только детерминированные варианты раскладки и пунктуации и умеет воздерживаться от замены. Inference заранее запускается после последней буквы; на границе используется только результат с совпадающими sequence, revision и focus, иначе немедленно остаётся V3. Сначала V4 работает в shadow-режиме и не меняет решения V3.

Теперь авто-конверсия обрабатывает частые короткие слова (`b` → `и`, `z` → `я`), длинные слова вроде `ghbdtncnde.` → `приветствую`, пунктуацию в конце (`ghbdtn,` → `привет,`) и неизвестные слитные слова вроде `cegthcgbyf` → `суперспина` (`супер` + `спина`). Исправление выполняется только после Space, Enter или Tab, но не посреди слова; пунктуация остаётся частью токена до этой границы, поэтому многоточие и повторные знаки не повреждаются переключением раскладки. Защищены цифры, URL/email, одиночные заглавные латинские буквы (`plan B`), ALL-CAPS, camelCase, смешанные идентификаторы, терминалы, IDE, менеджеры паролей и защищённые поля.

Для латинского ввода сначала работает English-first защита: частотный словарь и отдельный орфографический ESDB/SCOWL-слой более чем из 80 тысяч дополнительных форм. Точное английское слово остаётся неизменным; незнакомая, но похожая на английскую форма получает keep-bias. Переключение разрешается, когда исходная строка на английскую не похожа, а русская гипотеза сильнее по словарю, символьной модели или контексту. Для RU→EN тот же словарь подтверждает кандидат только тогда, когда исходная кириллическая форма неизвестна, слово не короче четырёх букв, а английская символьная модель выигрывает с калиброванным запасом.

Русские словоформы проверяются по офлайн-развёрнутому Hunspell-словарю LibreOffice, упакованному в компактный Bloom-фильтр размером 4 МБ и содержащему более миллиона форм. Он распознаёт, в частности, глагольные формы без исключений для отдельных слов и защищает корректные русские слова. Если обе интерпретации реальны (`туче`/`next`), RuSwitcher оставляет исходный текст, пока персональное обучение не даст более сильное основание.

Состояние ввода теперь ревизионное: обычный Backspace удаляет физическую клавишу из текущего токена, а удаление слова, навигация, Cut/Paste/Undo, клик и смена поля инвалидируют устаревший снимок. Перед автоматической заменой выполняется read-only AX-проверка, если поле её поддерживает, после чего вся замена отправляется одной упорядоченной транзакцией. Это защищает от выделения вместо замены, дублирования и удаления текста не у той каретки.

Отмена автоматического исправления или немедленное редактирование обучает RuSwitcher локально. V4 хранит только адаптер из 192 чисел и счётчики, но не введённый контекст; ручные исправления остаются подтверждёнными локальными парами. Всё обучение остаётся на этом Mac и сбрасывается в **Настройки → Дополнительно**. Явные списки **«Всегда конвертировать»** и **«Никогда не конвертировать»** остаются жёсткими правилами.

**Три списка исключений** для тонкой настройки (Настройки → Автоконверсия):
- **Приложения** — где авто-конверсия выключена (терминалы, IDE, менеджеры паролей уже в списке; менеджеры паролей удалить нельзя).
- **Никогда не конвертировать** — слова, которые трогать нельзя (ники, логины, бренды). Отмена ошибочной замены также автоматически снижает вероятность повторения.
- **Всегда конвертировать** — слова, которые исправлять всегда, даже если их нет в словаре (составные слова, сленг). Добавляйте **целевое** слово — то, что должно получиться.

### Режим удалённого стола (бета — новое в 2.5)

RuSwitcher работает через **Apple Screen Sharing**. Печатаете в сессии удалённого Mac — и неправильная раскладка исправляется прямо там, по триггеру или автоматически, как на локальной машине. Запустите RuSwitcher на **обеих** машинах и включите **Режим удалённого стола** (бета, помечен в меню). Конверсия происходит на управляемой машине, где и находится текст.

### Флаг у курсора (бета — новое в 2.6)

После переключения раскладки RuSwitcher может ненадолго показать флаг раскладки **прямо у текстового курсора** — видно, в какой раскладке печатаете, не глядя в меню-бар. Прячется, как только начинаете печатать. Включается в меню или Настройках (по умолчанию выключено). Работает там, где приложение отдаёт позицию курсора через Accessibility (нативные приложения и большинство текстовых полей); некоторые приложения, рисующие текст сами (например, редактор VS Code), позицию не отдают — там раскладку показывает встроенный индикатор macOS.

### Возможности

- **Любая пара раскладок** — настраивается любая пара из установленных в системе. Без захардкоженных таблиц.
- **Переключение раскладки из меню** *(новое в 2.6.1)* — выберите любую установленную раскладку прямо в меню-баре (флаг, имя, галочка на текущей) и кликните для переключения.
- **Настраиваемый триггер** — Option, Command, Control или Shift (левый/правый, одиночный/двойной тап), либо комбо из двух клавиш вроде ⌘+⇧.
- **Автоматическая конверсия** — опционально исправляет раскладку по ходу набора, включая частые короткие слова и пунктуацию в конце. По умолчанию выключено.
- **Режим удалённого стола (бета)** — исправление раскладки через Apple Screen Sharing, на управляемой машине.
- **Списки исключений** — список приложений плюс словари never-convert и always-convert.
- **Звук раскладки (опционально)** — короткий звук на первой букве после смены раскладки, чтобы *на слух* понимать раскладку.
- **Флаг у курсора (бета)** — ненадолго показывает флаг раскладки у текстового курсора сразу после переключения.
- **Монохромная иконка в меню-баре (опционально)** *(новое в 2.6.1)* — системная плашка `РУ/EN` вместо цветного флага, сама подстраивается под светлую/тёмную тему. По умолчанию выключена.
- **Universal-сборка** — нативно на Apple Silicon и Intel.
- **Без буфера обмена** — конвертированное слово печатается напрямую через синтез Unicode, поэтому работает даже в Electron / VS Code / Atom. Буфер обмена не трогается (только как запасной вариант для нестандартных приложений).
- **Умное определение слова** — конвертирует последнее набранное слово, включая знаки препинания.
- **Выделенный текст** — выделите любой текст и нажмите триггер для конвертации на месте.
- **Повторное нажатие — отмена** — обратная конвертация, если передумали.
- **Память раскладки по приложению** — запоминает активную раскладку для каждой программы и восстанавливает при возврате.
- **16 языков интерфейса** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português, Polski, 中文, 日本語, 한국어, Ελληνικά, Български, Հայերեն, ქართული.
- **Автозапуск при входе** — настроил и забыл.
- **Минимальное потребление** — без Electron и веб-вьюх, чистый Swift + AppKit.
- **Приватность по умолчанию** — анонимная статистика качества включается только вручную и не содержит слов, соседнего текста или названий приложений.

### Установка

**Homebrew (рекомендуется)**

```bash
brew tap rashn/ruswitcher
brew install --cask ruswitcher
```

Для обновления: `brew upgrade --cask ruswitcher`.

**Скачать DMG**

Скачайте последний `.dmg` со страницы [**Releases**](https://github.com/rashn/RuSwitcher/releases/latest), откройте и перетащите RuSwitcher в «Программы».

**Сборка из исходников**

```bash
git clone https://github.com/rashn/RuSwitcher.git
cd RuSwitcher
bash build_app.sh
cp -R RuSwitcher.app /Applications/
```

Требуется macOS 13+ и Xcode Command Line Tools.

### Разрешения

При первом запуске RuSwitcher запросит два системных разрешения macOS:

1. **Универсальный доступ (Accessibility)** — для чтения и изменения текста в приложениях.
2. **Мониторинг ввода (Input Monitoring)** — для отслеживания нажатий клавиш.

Программа автоматически добавляется в списки разрешений — вам нужно только включить тумблеры. Встроенный мастер разрешений проведёт по шагам.

### Технические детали

- Активный `CGEventTap` для упорядоченной автоматической замены; синтетические события помечаются и не попадают обратно в state machine.
- `UCKeyTranslate` (Carbon) для динамического маппинга символов между любой парой раскладок.
- `CGEvent.keyboardSetUnicodeString` для прямой печати конвертированного текста — без буфера обмена и побочных эффектов с pasteboard.
- Маркер `CGEventSource.userData` для фильтрации собственных симулированных событий.
- Версионированная memory-mapped RU/EN-модель, воспроизводимо собранная из закреплённой версии частотных Google Books n-gram data.
- Проверяемая по checksum FP16 Core ML byte-модель, которая только ранжирует варианты детерминированного lattice.
- Read-only `AXUIElement` range probes для проверки фокуса и хвоста перед кареткой; ручная замена выделения сначала использует AX, а fallback сохраняет все типы pasteboard.
- `SMAppService` для управления автозапуском.
- Без захардкоженных таблиц — работает с любыми установленными раскладками.

### Симуляция и проверка качества

Отдельный `RuSwitcherSimulator` параллельно прогоняет настоящий decoder по сгенерированным или JSONL-сценариям без Accessibility и эмуляции клавиатуры:

```bash
swift run -c release RuSwitcherSimulator --engine v4-shadow --jobs 8 --output simulation.json
```

`--engine v3|v4-shadow|v4-active` позволяет сравнить движки; JSON-отчёт содержит исходы V4, расхождения и p95/p99 задержки. `--input fixtures.jsonl` принимает тесты слов, `--phrase-input phrases.jsonl` — последовательные смешанные фразы, а `--phrase-results results.jsonl` сохраняет полный пошаговый отчёт. Для симуляции decoder HID не нужен. `scripts/run_hid_integration_tests.sh` изолирует отдельные event-tap сценарии, а `scripts/run_hid_batch_tests.sh` непрерывно вводит смешанные фрагменты корпуса в одном окне и ловит stale state, порчу пунктуации и дубли.

Анонимная статистика выключена по умолчанию и содержит только агрегированные исходы, причины и диапазоны длины. Отправка работает лишь в сборках с `RSStatisticsEndpoint`; без endpoint сетевых запросов нет.

### Настройки

Доступ через иконку в строке меню → **Настройки** (⌘,).

- **Общие** — триггер конвертации (одна клавиша или комбо), память раскладки по приложению, автозапуск, язык интерфейса, пара раскладок.
- **Автоконверсия** — автоматическая конверсия, **Режим удалённого стола (бета)** и три списка исключений (приложения, never-convert, always-convert).
- **О программе** — версия, донат, контакт, проверка обновлений.
- **Дополнительно** — версия Smart Engine/модели, сброс обучения, режим отладки и управление логами.

В меню в строке меню также есть быстрые тумблеры: «Автоматическая конверсия», «Звук раскладки», «Флаг у курсора» и «Режим удалённого стола».

### Поддержать проект

Если RuSwitcher вам полезен:

- [**Boosty**](https://boosty.to/ruswitcher) — донат
- **Star** на GitHub

### Лицензия

[MIT](LICENSE) — свободное использование, модификация и распространение.
