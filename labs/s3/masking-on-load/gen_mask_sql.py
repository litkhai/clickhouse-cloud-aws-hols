#!/usr/bin/env python3
"""Generate a ClickHouse expression that sets JSON fields to null, one constant regex per endpoint.

Input: a CSV with a header `endpoint,key` (one row per field to null; an endpoint may repeat).
Output (stdout): `multiIf(<ep> = '<endpoint>', <replace>, …, <src>)`, ready to paste into an MV or an
INSERT … SELECT. Endpoints with the same key set share one branch (`<ep> IN (…)`).

Each branch replaces `"key": <value>` with `"key":null` twice: in plain JSON and in JSON that is itself
encoded as a string (`\\"key\\": \\"…\\"`). <value> is a string, a number, true/false, or an array or
object without nesting; nested values are left as they are, so check for them after the load.

Why generate: a pattern built per row (concat('"', k, …) inside arrayFold) is not a constant, and on
ClickHouse Cloud 26.6 that was about 100 times slower than the same patterns as literals (README).

usage: gen_mask_sql.py rules.csv [--src raw0] [--ep ep]
"""
import argparse
import csv
import re
import sys
from collections import OrderedDict

# The value alternatives, as regex (RE2). Plain JSON, then JSON encoded inside a string.
VALUE = r'(?:"(?:[^"\\]|\\.)*"|-?[0-9][0-9.eE+-]*|true|false|\[[^\[\]]*\]|\{[^{}]*\})'
VALUE_ESC = r'(?:\\"(?:[^\\]|\\\\\\.|\\\\[^\\"])*\\"|-?[0-9][0-9.eE+-]*|true|false|\[[^\[\]]*\]|\{[^{}]*\})'


def sql_str(s: str) -> str:
    """A ClickHouse string literal: backslash and single quote escaped."""
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def replace_expr(src: str, keys: list[str]) -> str:
    alt = "|".join(re.escape(k) for k in keys)
    plain = sql_str(f'"({alt})"\\s*:\\s*{VALUE}')
    plain_to = sql_str('"\\1":null')
    esc = sql_str(f'\\\\"({alt})\\\\"\\s*:\\s*{VALUE_ESC}')
    esc_to = sql_str('\\\\"\\1\\\\":null')
    return f"replaceRegexpAll(replaceRegexpAll({src}, {plain}, {plain_to}), {esc}, {esc_to})"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("rules")
    ap.add_argument("--src", default="raw0", help="column or alias holding the JSON string")
    ap.add_argument("--ep", default="ep", help="column or alias holding the endpoint")
    a = ap.parse_args()

    keys_by_ep: "OrderedDict[str, list[str]]" = OrderedDict()
    with open(a.rules, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            ep, key = row["endpoint"].strip(), row["key"].strip()
            if ep and key and key not in keys_by_ep.setdefault(ep, []):
                keys_by_ep[ep].append(key)
    if not keys_by_ep:
        print("no rules", file=sys.stderr)
        return 1

    eps_by_keys: "OrderedDict[tuple, list[str]]" = OrderedDict()
    for ep, keys in keys_by_ep.items():
        eps_by_keys.setdefault(tuple(keys), []).append(ep)

    branches = []
    for keys, eps in eps_by_keys.items():
        cond = f"{a.ep} = {sql_str(eps[0])}" if len(eps) == 1 else f"{a.ep} IN ({', '.join(sql_str(e) for e in eps)})"
        branches.append(f"  {cond},\n    {replace_expr(a.src, list(keys))}")
    print("multiIf(\n" + ",\n".join(branches) + f",\n  {a.src})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
