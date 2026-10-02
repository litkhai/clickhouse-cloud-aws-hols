#!/usr/bin/env python3
"""Fetch ClickHouse Cloud usage cost for a date range and check what came back.

    python3 01-fetch.py --from 2026-08-21 --to 2026-10-01
    python3 01-fetch.py --from 2026-09-01 --to 2026-09-30 --filter tag:Environment=Production
    python3 01-fetch.py --input out/usage_cost_2026-09-01_2026-09-30.json   # no API call

Steps: fetch each window of at most 31 days (the API's limit), save the raw
response, flatten every record into out/usage_cost.jsonl, run the checks, print
the report. Amounts are CHC (ClickHouse Cloud credits), never currency.

Needs CHC_ORG_ID, CHC_API_KEY_ID and CHC_API_KEY_SECRET (environment or .env).
With --input no configuration is needed: saved raw responses are read instead
of calling the API, and everything after the fetch is identical.

Exit status: 0 all checks held; 1 a check failed or the API answered with an
error; 2 bad arguments. When a check fails, usage_cost.jsonl is NOT written and
one left by an earlier run is removed, so 02-load.sql cannot load a file that
did not pass.
"""
import argparse
import collections
import datetime
import json
import math
import os
import re
import sys
import urllib.parse

import chc_api

# The metrics each entity type is documented to carry. A record that carries a
# metric outside its type's set fails the run. (Spec read 2026-10-02; the same
# sets were seen in real responses.)
METRICS_BY_TYPE = {
    "datawarehouse": ("storageCHC", "backupCHC"),
    "service": (
        "computeCHC",
        "publicDataTransferCHC",
        "interRegionTier1DataTransferCHC",
        "interRegionTier2DataTransferCHC",
        "interRegionTier3DataTransferCHC",
        "interRegionTier4DataTransferCHC",
    ),
    "clickpipe": ("computeCHC", "dataTransferCHC", "initialLoadCHC"),
}

# One top-level column per metric in the jsonl (absent -> 0), in a fixed order.
METRIC_COLUMNS = (
    "storageCHC",
    "backupCHC",
    "computeCHC",
    "publicDataTransferCHC",
    "interRegionTier1DataTransferCHC",
    "interRegionTier2DataTransferCHC",
    "interRegionTier3DataTransferCHC",
    "interRegionTier4DataTransferCHC",
    "dataTransferCHC",
    "initialLoadCHC",
)

REQUIRED_FIELDS = ("date", "entityType", "entityId", "totalCHC")
DATE_PREFIX = re.compile(r"^\d{4}-\d{2}-\d{2}")

# Float tolerance for "equal" in the totals check and the informational check.
REL_TOL = 1e-9
ABS_TOL = 1e-6

MAX_FAILURE_LINES = 50


def close(a, b):
    return math.isclose(a, b, rel_tol=REL_TOL, abs_tol=ABS_TOL)


def utc_stamp(moment=None):
    """UTC as 'YYYY-MM-DD hh:mm:ss.fff' (what DateTime64(3, 'UTC') reads)."""
    moment = moment or datetime.datetime.now(datetime.timezone.utc)
    return moment.strftime("%Y-%m-%d %H:%M:%S") + ".%03d" % (moment.microsecond // 1000)


# --- reading windows ----------------------------------------------------------

def fetch_windows(args, out_dir):
    """One dict per window: label, response (parsed JSON), fetched_at."""
    config = chc_api.load_config(("CHC_ORG_ID",) + chc_api.API_VARS)
    org = urllib.parse.quote(config["CHC_ORG_ID"], safe="")
    fetched = []
    for start, end in chc_api.windows(args.from_date, args.to_date):
        params = [("from_date", start.isoformat()), ("to_date", end.isoformat())]
        # Repeated `filter=` parameters. The spec types `filter` as an array of
        # strings; this encoding has not been confirmed against the live API.
        params += [("filter", expression) for expression in args.filter]
        response = chc_api.api_get(
            "/v1/organizations/%s/usageCost" % org, params, config=config
        )
        stamp = utc_stamp()
        name = "usage_cost_%s_%s.json" % (start.isoformat(), end.isoformat())
        chc_api.write_private(
            os.path.join(out_dir, name), json.dumps(response, indent=2) + "\n"
        )
        fetched.append(
            {"label": "%s..%s" % (start, end), "response": response, "fetched_at": stamp}
        )
    return fetched


def read_windows(paths):
    stamp = utc_stamp()
    loaded = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            response = json.load(handle)
        loaded.append(
            {"label": os.path.basename(path), "response": response, "fetched_at": stamp}
        )
    return loaded


# --- flatten and check --------------------------------------------------------

def as_number(value):
    """float(value), or None when it is not a plain JSON number."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def flatten(record, fetched_at, failures, where):
    """Turn one API record into a jsonl row, or None when it is unusable.
    Appends a line to `failures` for every metric problem found."""
    if not isinstance(record, dict):
        failures.append("%s: a record is not an object" % where)
        return None
    absent = [name for name in REQUIRED_FIELDS if record.get(name) is None]
    if absent:
        failures.append(
            "%s: record without %s (entityId=%s)"
            % (where, ", ".join(absent), record.get("entityId"))
        )
        return None
    if not DATE_PREFIX.match(str(record["date"])):
        failures.append("%s: date %r is not YYYY-MM-DD" % (where, record["date"]))
        return None
    day = str(record["date"])[:10]
    entity_type, entity_id = record["entityType"], record["entityId"]
    total = as_number(record["totalCHC"])
    if total is None:
        failures.append("%s: %s %s %s totalCHC is not a number" % (where, day, entity_type, entity_id))
        return None

    # Metric assertion: only the metrics documented for the entity type.
    metrics = record.get("metrics")
    if metrics is None:
        metrics = {}
    if not isinstance(metrics, dict):
        failures.append("%s: %s %s %s metrics is not an object" % (where, day, entity_type, entity_id))
        return None
    allowed = METRICS_BY_TYPE.get(entity_type)
    if allowed is None:
        failures.append(
            "unknown entityType: %s %s %s (known: %s)"
            % (day, entity_type, entity_id, ", ".join(sorted(METRICS_BY_TYPE)))
        )
    values = {}
    for name, raw in metrics.items():
        if allowed is not None and name not in allowed:
            failures.append(
                "unexpected metric: %s %s %s carries %s (allowed for %s: %s)"
                % (day, entity_type, entity_id, name, entity_type, ", ".join(allowed))
            )
        number = as_number(raw)
        if number is None:
            failures.append(
                "bad metric value: %s %s %s %s = %r" % (day, entity_type, entity_id, name, raw)
            )
        else:
            values[name] = number

    def text(name):
        value = record.get(name)
        return "" if value is None else str(value)

    row = {
        "date": day,
        "entityType": entity_type,
        "entityId": entity_id,
        "entityName": text("entityName"),
        "serviceId": text("serviceId"),
        "dataWarehouseId": text("dataWarehouseId"),
        "organizationTier": text("organizationTier"),
        "locked": record.get("locked") is True,
        "totalCHC": total,
    }
    for name in METRIC_COLUMNS:
        row[name] = values.get(name, 0.0)
    row["fetched_at"] = fetched_at
    # Carried alongside the row for the informational checks; never written.
    row["_metric_sum"] = sum(values.values())
    row["_service_id_null"] = record.get("serviceId") is None
    return row


def collect(windows_read):
    """Flatten every window. Returns (rows, per_window, failures)."""
    rows, per_window, failures = [], [], []
    for window in windows_read:
        label, response = window["label"], window["response"]
        result = response.get("result") if isinstance(response, dict) else None
        if (
            not isinstance(result, dict)
            or not isinstance(result.get("costs"), list)
            or as_number(result.get("grandTotalCHC")) is None
        ):
            failures.append("%s: no result.costs list / numeric result.grandTotalCHC" % label)
            continue
        if response.get("status", 200) != 200:
            failures.append("%s: response status is %r" % (label, response.get("status")))
            continue
        window_rows = []
        for record in result["costs"]:
            row = flatten(record, window["fetched_at"], failures, label)
            if row is not None:
                window_rows.append(row)
        rows.extend(window_rows)
        per_window.append(
            {
                "label": label,
                "grand": float(result["grandTotalCHC"]),
                "sum": sum(r["totalCHC"] for r in window_rows),
                "records": len(result["costs"]),
                "usable": len(window_rows),
            }
        )
    return rows, per_window, failures


def check_totals(per_window):
    """Per window, sum(totalCHC) must equal grandTotalCHC."""
    failures = []
    for window in per_window:
        if window["usable"] == window["records"] and close(window["sum"], window["grand"]):
            continue
        failures.append(
            "totals differ in %s: sum(totalCHC) = %.6f, grandTotalCHC = %.6f, difference %.6f"
            % (window["label"], window["sum"], window["grand"], window["sum"] - window["grand"])
        )
    return failures


# --- output ---------------------------------------------------------------------

def write_jsonl(rows, path):
    lines = []
    for row in rows:
        clean = {k: v for k, v in row.items() if not k.startswith("_")}
        lines.append(json.dumps(clean, ensure_ascii=False))
    chc_api.write_private(path, "".join(line + "\n" for line in lines))


def money(value):
    return "%.4f" % value


def print_table(headers, table):
    widths = [len(h) for h in headers]
    for line in table:
        widths = [max(w, len(cell)) for w, cell in zip(widths, line)]
    right = {i for i, h in enumerate(headers) if h in ("CHC", "days", "records")}

    def fmt(cells):
        return "  " + "  ".join(
            cell.rjust(w) if i in right else cell.ljust(w)
            for i, (cell, w) in enumerate(zip(cells, widths))
        )

    print(fmt(headers))
    for line in table:
        print(fmt(line))


def informational(rows):
    """Counts only; none of these fails the run."""
    print("informational (not failures)")
    off = [r for r in rows if not close(r["_metric_sum"], r["totalCHC"])]
    print("  records where sum(metrics) != totalCHC: %d of %d" % (len(off), len(rows)))
    broken = collections.Counter()
    for r in rows:
        if r["_service_id_null"] != (r["entityType"] == "datawarehouse"):
            broken[r["entityType"]] += 1
    detail = ", ".join("%s %d" % (k, v) for k, v in sorted(broken.items()))
    print(
        "  records breaking 'serviceId is null iff datawarehouse': %d%s"
        % (sum(broken.values()), " (" + detail + ")" if detail else "")
    )
    tiers = collections.Counter(r["organizationTier"] or "(absent)" for r in rows)
    print("  organizationTier seen: %s" % (", ".join("%s x%d" % kv for kv in sorted(tiers.items())) or "-"))
    keys = collections.Counter((r["date"], r["entityType"], r["entityId"]) for r in rows)
    duplicates = sum(1 for n in keys.values() if n > 1)
    print("  duplicate (date, entityType, entityId) keys: %d" % duplicates)


def report(rows, per_window, range_text):
    grand = sum(w["grand"] for w in per_window)
    print("usage cost, in CHC (ClickHouse Cloud credits), not currency")
    print("  range:        %s" % range_text)
    print("  windows:      %d" % len(per_window))
    for window in per_window:
        print("    %s  %d records, grand total %s" % (window["label"], window["records"], money(window["grand"])))
    print("  records:      %d" % len(rows))
    print("  grand total:  %s CHC" % money(grand))
    if not rows:
        print("  note: no records in this range")
        return

    print()
    print("totals by entityType and metric")
    by_metric = collections.OrderedDict()
    for entity_type in sorted(METRICS_BY_TYPE):
        for name in METRICS_BY_TYPE[entity_type]:
            by_metric[(entity_type, name)] = 0.0
    for r in rows:
        for name in METRICS_BY_TYPE.get(r["entityType"], ()):
            by_metric[(r["entityType"], name)] += r[name]
    print_table(
        ["entityType", "metric", "CHC"],
        [[t, m, money(v)] for (t, m), v in by_metric.items()],
    )

    print()
    print("per entity")
    entities = {}
    for r in rows:
        entry = entities.setdefault((r["entityType"], r["entityId"]), {"name": r["entityName"], "total": 0.0, "days": set()})
        entry["total"] += r["totalCHC"]
        entry["days"].add(r["date"])
    ordered = sorted(entities.items(), key=lambda kv: (kv[0][0], -kv[1]["total"], kv[1]["name"]))
    print_table(
        ["entityType", "entityName", "CHC", "days"],
        [[key[0], e["name"] or "(no name)", money(e["total"]), str(len(e["days"]))] for key, e in ordered],
    )

    print()
    provisional = collections.OrderedDict()
    for r in sorted(rows, key=lambda r: r["date"]):
        if not r["locked"]:
            entry = provisional.setdefault(r["date"], [0, 0.0])
            entry[0] += 1
            entry[1] += r["totalCHC"]
    if provisional:
        print("provisional days (locked=false): these figures may still change")
        print_table(
            ["date", "records", "CHC"],
            [[d, str(n), money(v)] for d, (n, v) in provisional.items()],
        )
    else:
        print("provisional days (locked=false): none, every record is locked")
    print()
    informational(rows)


# --- main -------------------------------------------------------------------------

def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Fetch usage cost (CHC credits) for a date range, flatten it and check it."
    )
    parser.add_argument("--from", dest="from_date", metavar="YYYY-MM-DD", help="first day, inclusive")
    parser.add_argument("--to", dest="to_date", metavar="YYYY-MM-DD", help="last day, inclusive")
    parser.add_argument("--filter", action="append", default=[], metavar="EXPR",
                        help="usageCost filter, e.g. tag:Environment=Production; repeat for several")
    parser.add_argument("--input", nargs="+", metavar="FILE",
                        help="read saved raw responses instead of calling the API")
    parser.add_argument("--out", metavar="DIR", help="output directory (default: out/ next to the scripts)")
    args = parser.parse_args(argv)
    if args.input:
        if args.from_date or args.to_date or args.filter:
            parser.error("--input replaces the API call; do not combine it with --from, --to or --filter")
    else:
        if not (args.from_date and args.to_date):
            parser.error("--from and --to are required (or give --input)")
        try:
            args.from_date = chc_api.parse_date(args.from_date)
            args.to_date = chc_api.parse_date(args.to_date)
            chc_api.windows(args.from_date, args.to_date)
        except ValueError as exc:
            parser.error(str(exc))
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    out_dir = args.out or chc_api.OUT_DIR
    jsonl_path = os.path.join(out_dir, "usage_cost.jsonl")

    try:
        windows_read = read_windows(args.input) if args.input else fetch_windows(args, out_dir)
    except chc_api.ApiError as exc:
        print("API error: %s" % exc, file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print("cannot read input: %s" % exc, file=sys.stderr)
        return 1

    rows, per_window, failures = collect(windows_read)
    failures += check_totals(per_window)

    if args.input:
        days = sorted(r["date"] for r in rows)
        range_text = "%s .. %s (from the records)" % (days[0], days[-1]) if days else "(no records)"
    else:
        range_text = "%s .. %s" % (args.from_date, args.to_date)
    report(rows, per_window, range_text)
    print()

    if failures:
        stale = os.path.exists(jsonl_path)
        if stale:
            os.remove(jsonl_path)
        print("CHECKS FAILED (%d)" % len(failures), file=sys.stderr)
        for line in failures[:MAX_FAILURE_LINES]:
            print("  FAIL " + line, file=sys.stderr)
        if len(failures) > MAX_FAILURE_LINES:
            print("  ... and %d more" % (len(failures) - MAX_FAILURE_LINES), file=sys.stderr)
        print(
            "usage_cost.jsonl was not written%s" % (" (the one from an earlier run was removed)" if stale else ""),
            file=sys.stderr,
        )
        return 1

    write_jsonl(rows, jsonl_path)
    print("checks: every record carries only the metrics of its entityType; "
          "sum(totalCHC) equals grandTotalCHC in each of %d window(s)" % len(per_window))
    shown = os.path.relpath(jsonl_path)
    if shown.startswith(os.pardir):
        shown = os.path.abspath(jsonl_path)
    print("wrote %d rows to %s" % (len(rows), shown))
    return 0


if __name__ == "__main__":
    sys.exit(main())
