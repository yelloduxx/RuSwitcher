#!/usr/bin/env python3
"""Generate the authored alternating-layout phrase chain used by native HID QA."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from generate_hid_phrase_fixture import EN_TO_RU, RU_TO_EN, language_of


PHRASES = [
    ("en", "Сегодня снова я открыл project и написал план для новой версии."),
    ("ru", "We проверили input и нашли ошибку в старом модуле."),
    ("en", "Мы были в office и говорили о tests, но забыли про отчёт."),
    ("ru", "We sent файл к review, а потом вернулись to work."),
    ("en", "Проверь code, затем нажми save и отправь результат мне."),
    ("en", "Если cache пуст, то load идёт из disk, а не из сети."),
    ("ru", "After lunch я зайду в chat и отвечу на два вопроса."),
    ("en", "Когда status стал ready, мы нажали \"send\", но не закрыли окно."),
    ("ru", "План B готов, а пункт U пока открыт."),
    ("ru", "Can you send it to report@example.com, или лучше написать мне в chat?"),
    ("en", "Он спросил: \"Ты уже проверил use, или ещё нет?\""),
    ("en", "Если нажать Shift+U, появится U; если нажать букву B, останется B."),
    ("en", "Вопрос \"Почему?\" должен остаться вопросом, а ответ \"yes!\" - английским."),
    ("ru", "Research & Development работает в RU, but stays in EN."),
    ("en", "Точка. и запятая, остаются; а комбинации \"?!\", и \"...\" проверяются вместе!"),
    ("ru", "Адрес user.name+tag@example.com не меняется, а @ остаётся символом."),
]


def opposite_layout_text(expected: str, intended: str) -> str:
    mapping = RU_TO_EN if intended == "ru" else EN_TO_RU
    return "".join(mapping.get(character, character) for character in expected)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--start", type=int, default=1)
    parser.add_argument("--count", type=int)
    args = parser.parse_args()

    start = max(0, args.start - 1)
    phrases = PHRASES[start:start + args.count] if args.count else PHRASES[start:]
    phases: list[dict[str, str]] = []
    for first_layout, phrase in phrases:
        words = phrase.split(" ")
        for index, word in enumerate(words):
            source = first_layout if index % 2 == 0 else ("ru" if first_layout == "en" else "en")
            intended = language_of(word)
            typed = word if source == intended else opposite_layout_text(word, intended)
            phases.append({
                "sourceLanguage": source,
                "text": typed + ("\n" if index == len(words) - 1 else " "),
            })

    fixture = {
        "name": "authored-alternating-layout-phrases",
        "sourceIDs": [f"authored-{index:02d}" for index in range(start + 1, start + len(phrases) + 1)],
        "inputModel": "source layout alternates after every word; mismatched words use physical opposite-layout keys",
        "phases": phases,
        "expectedText": "\n".join(phrase for _, phrase in phrases) + "\n",
    }
    args.fixture.parent.mkdir(parents=True, exist_ok=True)
    args.fixture.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.manifest:
        args.manifest.write_text(
            "\n".join(f"{index:02d}. {phrase}" for index, (_, phrase) in enumerate(phrases, start=start + 1)) + "\n",
            encoding="utf-8",
        )
    print(f"generated {args.fixture}: {len(phrases)} phrases, {len(phases)} alternating token phases")


if __name__ == "__main__":
    main()
