#!/usr/bin/env python3
"""Turn an engine response capture into strict JSON.

The TopSAP engine answers with JavaScript-object-literal text: keys are bare
identifiers, not quoted strings, e.g.

    {method:"get_auth_param", gid:"auto", auth_port:"443", mtl:1300}

Every consumer here (svmk.py, the shell wrappers) needs strict JSON, so this
rewrites just the bare keys and leaves every string value byte-for-byte alone.
A scanner tracks string state, so a ':' inside a value is never mistaken for a
key separator, and true/false/null/numbers are left untouched.

    svjson.py CAPTURE OUT
"""
import sys


def quote_bare_keys(s):
    out = []
    i, n = 0, len(s)
    in_str = False
    esc = False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c.isalpha() or c == "_":
            j = i
            while j < n and (s[j].isalnum() or s[j] == "_"):
                j += 1
            k = j
            while k < n and s[k] in " \t\r\n":
                k += 1
            if k < n and s[k] == ":":
                out.append('"%s"' % s[i:j])
            else:
                out.append(s[i:j])
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: svjson.py CAPTURE OUT")
    raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    i = raw.find("{")
    j = raw.rfind("}")
    body = raw[i:j + 1] if i >= 0 and j > i else raw
    open(sys.argv[2], "w").write(quote_bare_keys(body))


main()
