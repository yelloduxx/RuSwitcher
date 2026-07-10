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

`LayoutRerankerV4.mlmodelc` is a derived model trained from those aggregate
word and phrase frequencies plus synthetic keyboard-layout corruptions. The
checked bootstrap artifact does not contain Wikipedia, Tatoeba, user text, or
other source sentences. Exact inputs, seed and artifact checksum are recorded
in `scripts/v4_training_sources.json`.
