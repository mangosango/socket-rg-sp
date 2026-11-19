"""Convert Godot 4.7 binary GDScript tokens (GDSC v101) back to GDScript text.

Usage: python3 -I gdc2gd.py <in.gdc> <out.gd>
"""
from pathlib import Path
import struct
import sys

NAMES = ("Empty Annotation Identifier Literal < <= > >= == != and or not && || ! & | ~ ^ << >> + - * ** / % "
         "= += -= *= **= /= %= <<= >>= &= |= ^= if elif else for while break continue pass return match when "
         "as assert await breakpoint class class_name const enum extends func in is namespace preload self signal "
         "static super trait var void yield [ ] { } ( ) , ; . .. ... : $ -> _ Newline Indent Dedent PI TAU INF NAN "
         "VCS ` ? Error EOF").split()
ANNOT, IDENT, LIT = 1, 2, 3
NEWLINE, INDENT, DEDENT = NAMES.index("Newline"), NAMES.index("Indent"), NAMES.index("Dedent")
EOF = len(NAMES) - 1

# The largest selected 0.10.1 script has 109,344 token bytes and 7,861 tokens.
MAX_BUFFER = 2 * 1024 * 1024
MAX_ITEMS = 64 * 1024
MAX_COLUMN = 4096
MAX_SOURCE = 2 * 1024 * 1024


def u32(b, o):
    if o + 4 > len(b):
        raise ValueError("truncated GDSC integer")
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
    length = 4 + n + (-n % 4)
    if o + length > len(b):
        raise ValueError("truncated GDSC string")
    return b[o + 4:o + 4 + n].decode("utf-8"), length


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
        if not names & 0x80000000:
            raise ValueError("old NodePath format")
        names &= 0x7FFFFFFF
        subs, fl = u32(b, p + 4), u32(b, p + 8)
        q, parts = p + 12, []
        if names + subs > MAX_ITEMS or names + subs > (len(b) - q) // 4:
            raise ValueError("invalid NodePath part count")
        for _ in range(names + subs):
            s, n = read_string(b, q)
            parts.append(s)
            q += n
        path = ("/" if fl & 1 else "") + "/".join(parts[:names])
        if subs:
            path += ":" + ":".join(parts[names:])
        return "^" + gd_str(path), q - o
    raise ValueError(f"unsupported constant variant type {t}")


def load_tokens(path, decompress=None):
    path = Path(path)
    with path.open("rb", buffering=0) as source:
        header = source.read(12)
        if len(header) != 12 or header[:4] != b"GDSC" or u32(header, 4) != 101:
            raise ValueError("expected a GDSC v101 file")
        size = u32(header, 8)
        if size > MAX_BUFFER or path.stat().st_size > MAX_BUFFER + 12:
            raise ValueError("GDSC exceeds script size limit")
        if size and decompress is None:
            import subprocess
            # A regular file supplies stdin so stdout can be bounded without a pipe deadlock.
            source.seek(12)
            with subprocess.Popen(["zstd", "-dc", "-M8MB"], stdin=source, stdout=subprocess.PIPE) as proc:
                buf = proc.stdout.read(size + 1)
                if len(buf) > size:
                    proc.kill()
                    raise ValueError("incorrect decompressed GDSC size")
                if proc.wait():
                    raise ValueError("invalid compressed GDSC")
        else:
            buf = source.read(MAX_BUFFER + 1)
            if len(buf) > MAX_BUFFER:
                raise ValueError("GDSC exceeds script size limit")
            if size:
                buf = decompress(buf, size)
        if size and len(buf) != size:
            raise ValueError("incorrect decompressed GDSC size")
    nid, nconst, nlines, ntok = (u32(buf, i) for i in (0, 4, 8, 12))
    if (max(nid, nconst, nlines, ntok) > MAX_ITEMS or nlines > ntok or
            16 + 4 * (nid + nconst) + 16 * nlines + 5 * ntok > len(buf)):
        raise ValueError("invalid GDSC table count")
    o, idents, consts = 16, [], []
    for _ in range(nid):
        n = u32(buf, o)
        o += 4
        if n > (len(buf) - o) // 4:
            raise ValueError("truncated GDSC identifier")
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
    if lines.keys() != cols.keys() or len(lines) != nlines or any(index >= ntok for index in lines):
        raise ValueError("invalid GDSC line table")
    toks = [(NEWLINE, (1, 1))]
    for i in range(ntok):
        if i in lines:
            toks.append((NEWLINE, (lines[i], cols[i])))
        if o >= len(buf):
            raise ValueError("truncated GDSC token")
        word = u32(buf, o) if buf[o] & 0x80 else buf[o]
        o += 8 if buf[o] & 0x80 else 5
        kind = word & 0x7F
        val = word >> 8
        if (kind > EOF or kind == NEWLINE or (kind in (ANNOT, IDENT) and val >= nid)
                or (kind == LIT and val >= nconst)):
            raise ValueError("invalid GDSC token")
        toks.append((kind, idents[val] if kind in (ANNOT, IDENT) else consts[val] if kind == LIT else None))
    if o != len(buf):
        raise ValueError("invalid GDSC token length")
    return toks


NO_SPACE_BEFORE = {")", "]", "}", ",", ".", ":", ";"}
NO_SPACE_AFTER = {"(", "[", "{", ".", "$", "@", "!", "~", "&"}
UNARY_CONTEXT = {None, "(", "[", "{", ",", "=", "return", ":", "and", "or", "not", "in", "if", "elif", "while",
                 "+", "-", "*", "/", "%", "**", "<", ">", "<=", ">=", "==", "!=", "+=", "-=", "*=", "/=", "->", "when"}


def render(toks, max_bytes=MAX_SOURCE):
    """Emit tokens on their original line numbers, indenting by the original column."""
    out, line, prev, indent = [], [], None, ""
    remaining = max_bytes

    def reserve(size):
        nonlocal remaining
        if size > remaining:
            raise ValueError("rendered GDScript exceeds source size limit")
        remaining -= size

    def flush():
        if line:
            reserve(len(indent) + 1)
            out.append(indent + "".join(line))

    for kind, val in toks:
        if kind == NEWLINE:
            flush()
            lineno, col = val
            if not 1 <= lineno <= MAX_ITEMS or not 1 <= col <= MAX_COLUMN:
                raise ValueError("invalid GDSC line or column")
            gap = max(0, lineno - 1 - len(out))
            reserve(gap)
            out.extend([""] * gap)
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
                reserve(1)
                line.append(" ")
        reserve(len(text.encode("utf-8")))
        line.append(text)
        prev = "unary" if unary_minus else text
    flush()
    if not out:
        reserve(1)
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    open(sys.argv[2], "w").write(render(load_tokens(sys.argv[1])))
