# Optional mechanical guard

`guard.py` requires Python 3.10+ and only its standard library. It does not call
an LLM, edit text, send network requests or execute embedded code. Read both
files first; compare against the original, not merely an intermediate draft.

```
python3 scripts/guard.py source.md candidate.md
python3 scripts/guard.py source.md candidate.md --anchors anchors.json
```

`anchors.json` is an optional JSON array of exact nonempty strings, e.g.
`["at most one", "Service A", "2026-09-08"]`. Every anchor must exist in the
source. Counts must survive. This is not a replacement for meaning review.

| Exit | Status | Interpretation |
|---|---|---|
| 0 | MECHANICAL_PASS_SEMANTICS_UNVERIFIED | Only implemented lexical/layout checks passed. |
| 1 | MECHANICAL_FAIL | A checked invariant differs. Inspect and repair/revert. |
| 2 | UNSUPPORTED | A recognized unsupported form prevents the check. Not a pass. |
| 3 | INPUT_ERROR | Read/encoding/anchor error. Not a pass. |

Supported: UTF-8 text; LF or CRLF (same convention on both sides); BOM and final
newline preservation; paragraphs with exact blank separators; ATX/setext
headings; single-line lists; fenced code with matching delimiter runs; inline
code including multiple backticks; simple/balanced-parenthesis link targets.
Code, headings, front matter, block quotes, reference definitions, indented
blocks and pipe-containing blocks/tables are opaque and exact-match protected.

Per aligned prose/list block, compare inline code, digit sequences, a limited
unit vocabulary, link destinations, bare URLs and recognizable paired quotes.
This is intentionally conservative, not a complete CommonMark parser. HTML,
MDX, inline math, unclosed fences/code/link delimiters, bare-CR or mixed newline
styles, and recognized multiline lists return UNSUPPORTED. Some unsupported
markup may remain undetected: a host-level parser is required for arbitrary
Markdown or rich documents. Never advertise this as format-complete validation.

Known blind spots: number words and uncommon units; arbitrary named entities;
complex/nested/unbalanced quotations; same-shape paragraph swaps/duplication;
negation, modality, causality, referents and factual/argument equivalence. A
negative sentence can become its opposite while all mechanical checks pass.
Adding anchors may detect a specific change but cannot prove general semantics.
Do not let this tool impose punctuation quotas or unnecessary paragraph edits.
An editorially valid inline-token reorder may be conservatively flagged: review
it and retain source order where equally clear; do not silently waive the check.
