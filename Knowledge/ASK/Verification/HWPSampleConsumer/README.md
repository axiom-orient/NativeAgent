# HWP/HWPX sample verification

`HWPSampleConsumer` exercises the public `HWPDocument` parser, the native
`ASKPageDocument` compiler, and the HWP layout renderer against real documents
from the upstream rHWP sample corpus.

The checked-in verifier does not copy binary fixtures into this repository.
Install or clone the upstream sample corpus separately, then run:

```sh
RHWP_SAMPLES_ROOT=/path/to/rhwp/samples \
  Scripts/verify-hwp-samples.sh
```

The default location is `$TMPDIR/ask-rhwp-upstream/samples`, which is the layout
used during local development. The selected corpus covers:

- HWPX manifest ordering, header styles, tables, and embedded images.
- HWPX floating/co-anchored table behavior and long table pagination.
- HWP5 tables and row/cell structure.
- HWP5 multi-page compressed body text with a large paragraph corpus.
- HWP5 `BinData` image objects.
- HWP5 equation controls without relying on ordinary paragraph text.
- HWP5 footnote controls and nested paragraph extraction.

Each input must produce at least one parsed section, renderable content, and a
non-empty layout result. The output also reports the native page-block count,
binary-object count, style metadata, and whether HWPX section order came from
the manifest spine.

The native parser treats documents as untrusted input. Its default limits are 128 MiB
for the input and each decoded stream, 384 MiB for the decoded payload, and 8,192
entries/sections. A host can pass a deliberate larger `ASKHWPParserLimits` value to
`ASKPageHWPNativeParser(limits:)` for trusted large documents.
