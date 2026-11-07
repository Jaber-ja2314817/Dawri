"""Translates a compiled Python pattern to an ICU one, keeping what Python means.

Python's \\w holds no combining mark, and its \\b, \\d and \\s follow str methods. ICU's own
\\w, \\b, \\d and \\s mean something else, so none of them may reach ICU. This rewrites:

    \\w   [\\p{L}\\p{N}_]        (rules.py asserts this set equals str.isalnum() or "_")
    \\W   [^\\p{L}\\p{N}_]
    \\d   \\p{Nd}               (the same as str.isdecimal)
    \\D   \\P{Nd}
    \\s   the explicit set of str.isspace
    \\S   its complement
    \\b   (?:(?<=W)(?!W)|(?<!W)(?=W)), where W is the \\w set

both inside and outside character classes, so the [^\\W\\d] of filters._HOURS becomes a nested
set. Alternatives stay in the order Python has them, which matters because both engines take
the first alternative that lets the whole pattern match.

The translator works on the pattern text and knows a short list of constructs. Anything else
raises Untranslatable, rather than passing through to mean something different.
"""

from __future__ import annotations

import re
import sys

WORD = r"\p{L}\p{N}_"
_INTROS = ("(?:", "(?=", "(?!", "(?<=", "(?<!")
_REPEAT = re.compile(r"\{\d+(?:,\d*)?\}")
_CONTROL = {"n": r"\n", "t": r"\t", "r": r"\r", "f": r"\f"}


class Untranslatable(ValueError):
    pass


def _point(code: int) -> str:
    return f"\\u{code:04X}" if code <= 0xFFFF else f"\\U{code:08X}"


def space_set() -> str:
    """The body of a character class for str.isspace, computed from Python itself."""
    points = [code for code in range(sys.maxunicode + 1) if chr(code).isspace()]
    parts = []
    index = 0
    while index < len(points):
        last = index
        while last + 1 < len(points) and points[last + 1] == points[last] + 1:
            last += 1
        first_text, last_text = _point(points[index]), _point(points[last])
        parts.append(first_text if index == last else f"{first_text}-{last_text}")
        index = last + 1
    return "".join(parts)


def boundary() -> str:
    word = f"[{WORD}]"
    return f"(?:(?<={word})(?!{word})|(?<!{word})(?={word}))"


def _outside(escaped: str, space: str) -> str:
    if escaped == "w":
        return f"[{WORD}]"
    if escaped == "W":
        return f"[^{WORD}]"
    if escaped == "d":
        return r"\p{Nd}"
    if escaped == "D":
        return r"\P{Nd}"
    if escaped == "s":
        return f"[{space}]"
    if escaped == "S":
        return f"[^{space}]"
    if escaped == "b":
        return boundary()
    if escaped in _CONTROL:
        return _CONTROL[escaped]
    if escaped.isascii() and not escaped.isalnum():
        return f"\\{escaped}"
    raise Untranslatable(f"\\{escaped} outside a character class")


def _inside(escaped: str, space: str) -> tuple[str, bool]:
    """The class body for an escape, and whether it stands for a single character."""
    if escaped == "w":
        return WORD, False
    if escaped == "W":
        return f"[^{WORD}]", False
    if escaped == "d":
        return r"\p{Nd}", False
    if escaped == "D":
        return r"\P{Nd}", False
    if escaped == "s":
        return space, False
    if escaped == "S":
        return f"[^{space}]", False
    if escaped in _CONTROL:
        return _CONTROL[escaped], True
    if escaped.isascii() and not escaped.isalnum():
        return f"\\{escaped}", True
    raise Untranslatable(f"\\{escaped} inside a character class")


def _literal_in_class(char: str) -> str:
    if char.isascii() and not char.isalnum():
        return _point(ord(char)) if char.isspace() else f"\\{char}"
    return char


_HEX_ESCAPE = re.compile(r"\\(?:u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|x[0-9a-fA-F]{2})")


def _hex_escape(pattern: str, index: int) -> tuple[str, int] | None:
    """A numeric escape means the same in both engines, so it passes through unchanged."""
    match = _HEX_ESCAPE.match(pattern, index)
    return None if match is None else (match.group(), match.end())


def _character_class(pattern: str, start: int, space: str) -> tuple[str, int]:
    index = start + 1
    negated = pattern[index] == "^"
    if negated:
        index += 1
    parts: list[str] = []
    first = True
    while True:
        if index >= len(pattern):
            raise Untranslatable("an unclosed character class")
        char = pattern[index]
        if char == "]" and not first:
            break
        first = False
        if char == "[":
            raise Untranslatable("[ inside a character class")
        numeric = _hex_escape(pattern, index)
        if numeric is not None:
            body, index = numeric
            single = True
        elif char == "\\":
            body, single = _inside(pattern[index + 1], space)
            index += 2
        else:
            body, single = _literal_in_class(char), True
            index += 1
        if single and pattern[index] == "-" and pattern[index + 1] != "]":
            index += 1
            numeric = _hex_escape(pattern, index)
            if numeric is not None:
                high, index = numeric
            elif pattern[index] in "\\[":
                raise Untranslatable("an escape as the end of a range")
            else:
                high = _literal_in_class(pattern[index])
                index += 1
            body = f"{body}-{high}"
        parts.append(body)
    return f"[{'^' if negated else ''}{''.join(parts)}]", index + 1


def translate(pattern: str, space: str) -> str:
    out: list[str] = []
    index = 0
    while index < len(pattern):
        char = pattern[index]
        numeric = _hex_escape(pattern, index)
        if numeric is not None:
            out.append(numeric[0])
            index = numeric[1]
        elif char == "\\":
            out.append(_outside(pattern[index + 1], space))
            index += 2
        elif char == "[":
            text, index = _character_class(pattern, index, space)
            out.append(text)
        elif char == "(":
            if pattern.startswith("(?", index):
                intro = next((item for item in _INTROS if pattern.startswith(item, index)), None)
                if intro is None:
                    raise Untranslatable(f"the group at {pattern[index:index + 6]!r}")
                out.append(intro)
                index += len(intro)
            else:
                out.append("(")
                index += 1
        elif char in ")|*+?":
            out.append(char)
            index += 1
        elif char == "{":
            repeat = _REPEAT.match(pattern, index)
            if repeat is None:
                raise Untranslatable(f"a literal {{ at {pattern[index:index + 6]!r}")
            out.append(repeat.group())
            index = repeat.end()
        elif char in ".^$":
            raise Untranslatable(f"{char} differs between Python and ICU")
        elif char in "]}":
            out.append(f"\\{char}")
            index += 1
        else:
            out.append(char)
            index += 1
    return "".join(out)


def options(flags: int) -> list[str]:
    """NSRegularExpression options for a compiled pattern's flags."""
    known = re.UNICODE | re.IGNORECASE
    if flags & ~known:
        raise Untranslatable(f"flags {flags}")
    return ["caseInsensitive"] if flags & re.IGNORECASE else []


def group_count(pattern: re.Pattern) -> int:
    return pattern.groups
