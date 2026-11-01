"""Convert Godot 4.7 binary GDScript tokens (GDSC v101) back to GDScript text.

Usage: python3 -I gdc2gd.py <in.gdc> <out.gd>
"""
import struct
import subprocess
import sys

NAMES = ("Empty Annotation Identifier Literal < <= > >= == != and or not && || ! & | ~ ^ << >> + - * ** / % "
         "= += -= *= **= /= %= <<= >>= &= |= ^= if elif else for while break continue pass return match when "
         "as assert await breakpoint class class_name const enum extends func in is namespace preload self signal "
         "static super trait var void yield [ ] { } ( ) , ; . .. ... : $ -> _ Newline Indent Dedent PI TAU INF NAN "
         "VCS ` ? Error EOF").split()
ANNOT, IDENT, LIT = 1, 2, 3
NEWLINE, INDENT, DEDENT = NAMES.index("Newline"), NAMES.index("Indent"), NAMES.index("Dedent")
EOF = len(NAMES) - 1


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def gd_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r") + '"'


def fmt_float(f):
    r = repr(f)
    if r in ("inf", "-inf", "nan"):
        return {"inf": "INF", "-inf": "-INF", "nan": "NAN"}[r]
    return r if ("." in r or "e" in r) else r + ".0"


def read_string(b, o):
    n = u32(b, o)
    s = b[o + 4:o + 4 + n].decode("utf-8")
    return s, 4 + n + ((4 - n % 4) % 4)


def decode_variant(b, o):
    """Return (gdscript_literal_text, byte_length)."""
    h = u32(b, o)
    t, flags = h & 0xFFFF, h >> 16
    p = o + 4
    if t == 0:
        return "null", 4
    if t == 1:
        return ("true" if u32(b, p) else "false"), 8
    if t == 2:
        if flags & 1:
            return str(struct.unpack_from("<q", b, p)[0]), 12
        return str(struct.unpack_from("<i", b, p)[0]), 8
    if t == 3:
        if flags & 1:
            return fmt_float(struct.unpack_from("<d", b, p)[0]), 12
        return fmt_float(struct.unpack_from("<f", b, p)[0]), 8
    if t in (4, 21):
        s, n = read_string(b, p)
        return ("&" if t == 21 else "") + gd_str(s), 4 + n
    if t == 22:  # NodePath, new format
        names = u32(b, p)
        assert names & 0x80000000, "old NodePath format"
        names &= 0x7FFFFFFF
        subs, fl = u32(b, p + 4), u32(b, p + 8)
        q, parts = p + 12, []
        for _ in range(names + subs):
            s, n = read_string(b, q)
            parts.append(s)
            q += n
        path = ("/" if fl & 1 else "") + "/".join(parts[:names])
        if subs:
            path += ":" + ":".join(parts[names:])
        return "^" + gd_str(path), q - o
    raise ValueError(f"unsupported constant variant type {t}")


def load_tokens(path):
    raw = open(path, "rb").read()
    assert raw[:4] == b"GDSC", "not a GDSC file"
    assert u32(raw, 4) == 101, f"tokenizer version {u32(raw, 4)}"
    size = u32(raw, 8)
    buf = raw[12:] if size == 0 else subprocess.run(["zstd", "-dc"], input=raw[12:], capture_output=True, check=True).stdout
    assert size == 0 or len(buf) == size
    nid, nconst, nlines, ntok = (u32(buf, i) for i in (0, 4, 8, 12))
    o, idents, consts = 16, [], []
    for _ in range(nid):
        n = u32(buf, o)
        o += 4
        chars = bytes(c ^ 0xB6 for c in buf[o:o + n * 4])
        idents.append(chars.decode("utf-32-le"))
        o += n * 4
    for _ in range(nconst):
        text, n = decode_variant(buf, o)
        consts.append(text)
        o += n
    lines = {u32(buf, o + 8 * i): u32(buf, o + 8 * i + 4) for i in range(nlines)}
    o += nlines * 8
    cols = {u32(buf, o + 8 * i): u32(buf, o + 8 * i + 4) for i in range(nlines)}
    o += nlines * 8
    toks = []
    for i in range(ntok):
        if i in lines:
            toks.append((NEWLINE, (lines[i], cols[i])))
        word = u32(buf, o) if buf[o] & 0x80 else buf[o]
        o += 8 if buf[o] & 0x80 else 5
        kind = word & 0x7F
        val = word >> 8
        toks.append((kind, idents[val] if kind in (ANNOT, IDENT) else consts[val] if kind == LIT else None))
    assert o == len(buf), "trailing data"
    return [(NEWLINE, (1, 1))] + toks


NO_SPACE_BEFORE = {")", "]", "}", ",", ".", ":", ";"}
NO_SPACE_AFTER = {"(", "[", "{", ".", "$", "@", "!", "~", "&"}
UNARY_CONTEXT = {None, "(", "[", "{", ",", "=", "return", ":", "and", "or", "not", "in", "if", "elif", "while",
                 "+", "-", "*", "/", "%", "**", "<", ">", "<=", ">=", "==", "!=", "+=", "-=", "*=", "/=", "->", "when"}


def render(toks):
    """Emit tokens on their original line numbers, indenting by the original column."""
    out, line, prev, paren, indent = [], [], None, 0, ""

    def flush():
        if line:
            out.append(indent + "".join(line))

    for kind, val in toks:
        if kind == NEWLINE:
            flush()
            lineno, col = val
            while len(out) < lineno - 1:
                out.append("")
            line, prev, indent = [], None, "\t" * (col - 1)
            continue
        text = val if kind in (ANNOT, IDENT, LIT) else NAMES[kind]
        unary_minus = text in ("-", "+") and prev in UNARY_CONTEXT
        if line:
            glue = (text in NO_SPACE_BEFORE or prev in NO_SPACE_AFTER
                    or (text in ("(", "[") and prev not in UNARY_CONTEXT and prev not in ("and", "or", "not", "in", "is", "as"))
                    or prev == "unary")
            if text == ":" and prev is not None:
                glue = True
            if not glue:
                line.append(" ")
        line.append(text)
        prev = "unary" if unary_minus else text
        if text in ("(", "[", "{"):
            paren += 1
        elif text in (")", "]", "}"):
            paren -= 1
    flush()
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    open(sys.argv[2], "w").write(render(load_tokens(sys.argv[1])))
