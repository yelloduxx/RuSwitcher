# Third-Party Data Notices

## Google Books n-gram frequency lists

`language-model-v1.bin` contains derived aggregate statistics from the
`orgtre/google-books-ngram-frequency` project, revision
`e20471c15a758be3362b16d07870b34df4f7ccc3`.

The source data is licensed under the Creative Commons Attribution 3.0
Unported License. Copyright and attribution belong to the source project and
the Google Books Ngram Corpus contributors.

- Source: https://github.com/orgtre/google-books-ngram-frequency
- License: https://creativecommons.org/licenses/by/3.0/

The application ships only the derived frequency tables required for local
language scoring. It does not contain source texts and never downloads model
data at runtime.

## English Speller Database / SCOWL

The English plausibility lexicon in `language-model-v1.bin` is
derived from the English Speller Database (formerly SCOWL), release
`rel-2026.02.25`, commit `7e99edab8e32f9f9ea2b15f249ca8d4d67237410`.
RuSwitcher uses the level-60 American/British word list primarily to protect
valid English source words. It may also confirm an RU-to-EN target behind
source-language and character-probability safety gates; it is never treated as
target-word frequency evidence by itself.

- Source: https://github.com/en-wl/wordlist
- Copyright: 2000-2026 Kevin Atkinson
- Full notice: `SCOWL_COPYRIGHT.txt`

## LibreOffice Russian Hunspell Dictionary

The Russian spelling Bloom filter in `language-model-v1.bin` is derived from
the `ru_RU` Hunspell dictionary and suffix rules in LibreOffice Dictionaries,
commit `38d96a4d54ec3449cf7f28cddae1fce32e2b15a7`. RuSwitcher expands the rules
offline and ships only a compact probabilistic membership filter. This derived
representation is modified and is not a replacement dictionary distribution.

- Source: https://github.com/LibreOffice/dictionaries/tree/master/ru_RU
- Copyright: 1997-2008 Alexander I. Lebedev
- License: permissive three-clause notice in `RUSSIAN_HUNSPELL_COPYRIGHT.txt`

`LayoutRerankerV4.mlmodelc` is a derived model trained from those aggregate
word and phrase frequencies plus synthetic keyboard-layout corruptions. The
checked bootstrap artifact does not contain Wikipedia, Tatoeba, user text, or
other source sentences. Exact inputs, seed and artifact checksum are recorded
in `scripts/v4_training_sources.json`.
