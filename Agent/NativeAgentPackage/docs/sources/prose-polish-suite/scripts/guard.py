#!/usr/bin/env python3
"""Read-only preservation guard. This is NOT a writer or semantic validator.

Subset: UTF-8 plain text, ATX/setext headings, single-line list items, fenced
code, inline code, simple Markdown links. Tables, block quotes, reference
links, front matter and indented code are opaque. HTML/MDX and inline math
are unsupported. Nonzero exits: 1 mechanical mismatch, 2 unsupported, 3 I/O.
"""
from __future__ import annotations
import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import sys

PASS = 'MECHANICAL_PASS_SEMANTICS_UNVERIFIED'
FENCE = re.compile(r'^ {0,3}(`{3,}|~{3,})([^\r\n]*)$')
HEADING = re.compile(r'^ {0,3}#{1,6}(?:\s|$)')
LIST = re.compile(r'^( {0,3}(?:[-+*]|\d+[.)])\s+)(.*)$')
RULE = re.compile(r'^ {0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$')
NUMBER = re.compile(r'(?<![A-Za-z0-9_])(?:[+−-]|[$€£¥₩])?\d+(?:[.,:/\-]\d+)*(?:[%％‰°]|\s?(?:milliseconds?|seconds?|minutes?|hours?|bytes?|km/h|m/s²|m/s|[kMGTP]?B|[kMG]?Hz|ms|μs|µs|ns|kg|mg|km|cm|mm|mL|ml|kW|MW|°C|°F|s|h|m|L|l|A|V|W|초|분|시간|일|개월|년|명|개|원|秒|分钟|分|小时|日|年|人|円|元|个))?(?![A-Za-z0-9_])', re.UNICODE)
DIGITS = re.compile(r'\d+(?:[.,:/\-]\d+)*')
URL = re.compile(r'(?:https?://|mailto:)[^\s<>"「」『』《》]+')
PAIRS = [('“', '”'), ('‘', '’'), ('«', '»'), ('「', '」'), ('『', '』'), ('《', '》')]

class Unsupported(ValueError):
    pass

@dataclass(frozen=True)
class Block:
    kind: str
    text: str
    marker: str = ''

    @property
    def opaque(self) -> bool:
        return self.kind in {'code', 'frontmatter', 'opaque', 'heading', 'rule'}


def _eol_profile(text: str) -> tuple[str, bool, bool]:
    endings = re.findall(r'\r\n|\n|\r', text)
    kinds = set(endings)
    if len(kinds) > 1:
        raise Unsupported('Mixed line endings require a byte-aware host review.')
    if '\r' in kinds:
        raise Unsupported('Bare-CR line endings are not supported.')
    return next(iter(kinds), ''), text.endswith(('\n', '\r')), text.startswith('\ufeff')


def blocks(text: str) -> list[Block]:
    """Parse only the stated subset; never execute or evaluate source content."""
    _eol_profile(text)
    text = text.removeprefix('\ufeff')
    lines = text.splitlines(keepends=True)
    out: list[Block] = []
    i = 0
    def bare(n: int) -> str:
        return lines[n].rstrip('\r\n')
    while i < len(lines):
        line = bare(i)
        if not line.strip():
            j = i + 1
            while j < len(lines) and not bare(j).strip():
                j += 1
            out.append(Block('gap', ''.join(lines[i:j])))
            i = j
            continue
        if i == 0 and line == '---':
            j = i + 1
            while j < len(lines) and bare(j) not in {'---', '...'}:
                j += 1
            if j == len(lines):
                raise Unsupported('Unclosed front matter.')
            out.append(Block('frontmatter', ''.join(lines[i:j+1])))
            i = j + 1
            continue
        fence = FENCE.match(line)
        if fence:
            delim = fence.group(1)
            if delim[0] == '`' and '`' in fence.group(2):
                raise Unsupported('Backtick in fence info string.')
            close = re.compile(r'^ {0,3}' + re.escape(delim[0]) + '{' + str(len(delim)) + r',}\s*$')
            j = i + 1
            while j < len(lines) and not close.match(bare(j)):
                j += 1
            if j == len(lines):
                raise Unsupported('Unclosed code fence.')
            out.append(Block('code', ''.join(lines[i:j+1])))
            i = j + 1
            continue
        if HEADING.match(line):
            out.append(Block('heading', lines[i])); i += 1; continue
        if i + 1 < len(lines) and re.fullmatch(r' {0,3}(?:=+|-+)\s*', bare(i+1)):
            out.append(Block('heading', ''.join(lines[i:i+2]))); i += 2; continue
        if RULE.match(line):
            out.append(Block('rule', lines[i])); i += 1; continue
        if re.match(r'^ {0,3}>|^ {0,3}\[[^\]]+\]:|^ {4}|^\t', line) or '|' in line:
            j = i + 1
            while j < len(lines) and bare(j).strip():
                j += 1
            out.append(Block('opaque', ''.join(lines[i:j]))); i = j; continue
        li = LIST.match(line)
        if li:
            out.append(Block('list', lines[i], li.group(1)))
            i += 1
            if i < len(lines) and bare(i).strip() and not LIST.match(bare(i)) and not HEADING.match(bare(i)) and not FENCE.match(bare(i)):
                raise Unsupported('Multiline/nested list: use explicit opaque spans or a Markdown-aware host.')
            continue
        j = i + 1
        while j < len(lines) and bare(j).strip() and not any((FENCE.match(bare(j)), HEADING.match(bare(j)), LIST.match(bare(j)), RULE.match(bare(j)))):
            j += 1
        out.append(Block('prose', ''.join(lines[i:j]))); i = j
    for block in out:
        if not block.opaque and block.kind != 'gap':
            _, masked = inline_code(block.text)
            if re.search(r'<(?:/?[A-Za-z][\w:-]*\b|!--|!DOCTYPE)', masked):
                raise Unsupported('HTML/MDX is outside the supported subset.')
            if re.search(r'(?<!\\)\$[^\n$]+(?<!\\)\$|\\\(|\\\[|\\begin\{', masked):
                raise Unsupported('Inline mathematical markup requires a math-aware host.')
    return out


def inline_code(text: str) -> tuple[list[str], str]:
    """Preserve delimiter-run length, including double-backtick spans."""
    matches = list(re.finditer(r'(?<!\\)(?<!`)`+(?!`)', text))
    spans: list[tuple[int, int]] = []
    k = 0
    while k < len(matches):
        start = matches[k]
        j = k + 1
        while j < len(matches) and matches[j].group() != start.group():
            j += 1
        if j == len(matches):
            raise Unsupported('Unclosed inline-code delimiter.')
        spans.append((start.start(), matches[j].end()))
        k = j + 1
    chars = list(text)
    for a, b in spans:
        chars[a:b] = ' ' * (b-a)
    return [text[a:b] for a,b in spans], ''.join(chars)


def links(text: str) -> list[str]:
    """Capture complete destination/title bytes, with balanced parentheses."""
    found: list[str] = []
    for m in re.finditer(r'(?<!\\)\]\(', text):
        start = m.end()
        depth, j = 1, start
        while j < len(text) and depth:
            if text[j] == '\\':
                j += 2; continue
            if text[j] == '(': depth += 1
            if text[j] == ')': depth -= 1
            j += 1
        if depth:
            raise Unsupported('Unclosed Markdown link destination.')
        found.append(text[start:j-1])
    return found


def protected(text: str) -> dict[str, list[str]]:
    code, masked = inline_code(text)
    quotes: list[tuple[int, str]] = []
    for left, right in PAIRS:
        # Curly apostrophes inside a word are content, not the closing quote.
        if left == '‘':
            pattern = r"‘(?:\\.|(?<=\w)’(?=\w)|[^‘’\n])*’"
        else:
            pattern = re.escape(left) + '[^' + re.escape(left+right) + '\\n]*' + re.escape(right)
        quotes.extend((m.start(), m.group()) for m in re.finditer(pattern, masked))
    for pattern in [r'"(?:\\.|[^"\n])*"', r"(?<![\w])'(?:\\.|(?<=\w)'(?=\w)|[^'\n])*'(?![\w])"]:
        quotes.extend((m.start(), m.group()) for m in re.finditer(pattern, masked))
    return {
        'inline_code': code,
        'numbers': DIGITS.findall(masked),
        'number_units_known': NUMBER.findall(masked),
        'links': links(masked),
        # Keep punctuation as written; the conservative URL check may flag
        # punctuation-only changes around a bare URL for manual review.
        'urls': URL.findall(masked),
        'quotes': [q for _,q in sorted(quotes)],
    }


def compare(source: str, candidate: str, anchors: list[str] | None = None) -> dict:
    errors: list[dict] = []
    try:
        if _eol_profile(source) != _eol_profile(candidate):
            errors.append({'check':'encoding_layout', 'detail':'BOM, newline style or terminal newline differs.'})
        a, b = blocks(source), blocks(candidate)
        if len(a) != len(b):
            errors.append({'check':'block_inventory', 'source':len(a), 'candidate':len(b)})
        for i,(x,y) in enumerate(zip(a,b),1):
            if (x.kind,x.marker) != (y.kind,y.marker):
                errors.append({'block':i,'check':'block_kind_or_marker','source':x.kind,'candidate':y.kind})
                continue
            if (x.opaque or x.kind == 'gap') and x.text != y.text:
                errors.append({'block':i,'check':'opaque_or_gap_changed','kind':x.kind})
            elif x.kind in {'prose','list'}:
                px,py = protected(x.text), protected(y.text)
                for key in px:
                    if px[key] != py[key]:
                        errors.append({'block':i,'check':key,'source':px[key],'candidate':py[key]})
        for anchor in anchors or []:
            if not isinstance(anchor,str) or not anchor:
                raise ValueError('Anchors must be nonempty strings.')
            if source.count(anchor) == 0:
                raise ValueError(f'Anchor absent from source: {anchor!r}')
            if source.count(anchor) != candidate.count(anchor):
                errors.append({'check':'explicit_anchor_count','anchor':anchor})
    except Unsupported as exc:
        return {'status':'UNSUPPORTED','reason':str(exc),'errors':errors,'semantic_verification':'NOT_PERFORMED'}
    return {
        'status': 'MECHANICAL_FAIL' if errors else PASS,
        'errors':errors,
        'source_sha256':hashlib.sha256(source.encode('utf-8')).hexdigest(),
        'candidate_sha256':hashlib.sha256(candidate.encode('utf-8')).hexdigest(),
        'source_blocks':len(a), 'candidate_blocks':len(b),
        'opaque_blocks':sum(x.opaque for x in a),
        'semantic_verification':'NOT_PERFORMED',
        'limitations':['No semantic equivalence or fluency judgement.', 'Numeral/quote/unit coverage is lexical and incomplete.', 'No arbitrary Markdown/HTML parser; unsupported forms require host review.', 'Unanchored same-shape duplicate/reordered claims may pass.']
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    parser.add_argument('candidate',type=Path)
    parser.add_argument('--anchors',type=Path,help='Optional JSON array of exact protected strings.')
    args=parser.parse_args(argv)
    try:
        # read_bytes deliberately avoids universal-newline conversion.
        s=args.source.read_bytes().decode('utf-8')
        c=args.candidate.read_bytes().decode('utf-8')
        anchors=json.loads(args.anchors.read_text(encoding='utf-8')) if args.anchors else None
        if anchors is not None and not isinstance(anchors,list):
            raise ValueError('Anchors file must contain a JSON array.')
        result=compare(s,c,anchors)
    except (OSError,UnicodeError,ValueError) as exc:
        print(json.dumps({'status':'INPUT_ERROR','reason':str(exc)},ensure_ascii=False))
        return 3
    print(json.dumps(result,ensure_ascii=False,indent=2))
    return {PASS:0,'MECHANICAL_FAIL':1,'UNSUPPORTED':2}[result['status']]

if __name__ == '__main__':
    sys.exit(main())
