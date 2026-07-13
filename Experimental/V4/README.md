# RuSwitcher V4 Research

V4 is an offline research project for a contextual Core ML reranker. It is not
linked into the RuSwitcher application, its simulator, or the default test
suite.

Run the experiment explicitly:

```bash
swift test --package-path Experimental/V4
```

Production uses the V3 `LayoutDecoder` from `RuSwitcherCore`. V4 may return to
the application only after it beats V3 on a held-out corpus without increasing
false conversions.
