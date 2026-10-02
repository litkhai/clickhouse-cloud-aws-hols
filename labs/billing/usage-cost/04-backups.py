#!/usr/bin/env python3
"""Backup size per service, next to the backup CHC billed on its data warehouse.

    python3 04-backups.py

Run 01-fetch.py first: the service ids, their data warehouse ids and the billed
backupCHC come from out/usage_cost.jsonl. For each service this calls
GET /v1/organizations/{organizationId}/services/{serviceId}/backups, saves the raw
response to out/backups_<serviceId>.json and prints the backup count, the
full/incremental split, the size of the finished backups and the oldest and newest
start time.

Needs CHC_ORG_ID, CHC_API_KEY_ID and CHC_API_KEY_SECRET (environment or .env). The
key needs the permission control-plane:service:view-backups; without it the API
answers 403 and this script says so and exits non-zero.

Amounts are CHC (ClickHouse Cloud credits), never currency.
"""
import argparse
import collections
import json
import os
import sys
import urllib.parse

import chc_api

MAX_PAGES = 100


def human_bytes(count):
    value = float(count)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return "%d B" % value if unit == "B" else "%.2f %s" % (value, unit)
        value /= 1024.0


def read_jsonl(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def services_and_backup_chc(rows):
    """From the flattened records: {serviceId: {name, warehouse}} and
    {warehouseId: {chc, days}} for the datawarehouse rows."""
    latest = {}
    for row in rows:  # one row per (date, entityType, entityId): keep the last
        latest[(row["date"], row["entityType"], row["entityId"])] = row
    services, warehouses = collections.OrderedDict(), {}
    for row in sorted(latest.values(), key=lambda r: (r["date"], r["entityType"], r["entityId"])):
        if row["entityType"] == "service":
            sid = row["serviceId"] or row["entityId"]
            entry = services.setdefault(sid, {"name": row["entityName"], "warehouse": row["dataWarehouseId"]})
            entry["name"] = row["entityName"] or entry["name"]
            entry["warehouse"] = row["dataWarehouseId"] or entry["warehouse"]
        elif row["entityType"] == "datawarehouse":
            key = row["dataWarehouseId"] or row["entityId"]
            entry = warehouses.setdefault(key, {"chc": 0.0, "days": set()})
            entry["chc"] += row["backupCHC"]
            entry["days"].add(row["date"])
    return services, warehouses


def fetch_backups(org, service_id, config):
    """All pages of the backups list. Returns (backups, raw) where raw is what
    gets saved: the single response, or {"pages": [...]} when there were several."""
    path = "/v1/organizations/%s/services/%s/backups" % (
        urllib.parse.quote(org, safe=""), urllib.parse.quote(service_id, safe="")
    )
    pages, backups, params, seen = [], [], None, set()
    for _ in range(MAX_PAGES):
        response = chc_api.api_get(path, params, config=config)
        pages.append(response)
        result = response.get("result") if isinstance(response, dict) else None
        backups.extend(result if isinstance(result, list) else [])
        # The published spec does not describe pagination for this call. If the
        # response carries a nextCursor anyway, pass it back as `cursor`; both the
        # field and the parameter name are unverified.
        cursor = response.get("nextCursor") if isinstance(response, dict) else None
        if not cursor or cursor in seen:
            break
        seen.add(cursor)
        params = [("cursor", cursor)]
    return backups, pages[0] if len(pages) == 1 else {"pages": pages}


def summarize(backups):
    kinds = collections.Counter(b.get("type") for b in backups)
    states = collections.Counter(b.get("status") for b in backups)
    done = [b for b in backups if b.get("status") == "done"]
    sized = [b for b in done if isinstance(b.get("sizeInBytes"), (int, float))]
    started = sorted(b["startedAt"] for b in backups if b.get("startedAt"))
    return {
        "count": len(backups),
        "kinds": kinds,
        "states": states,
        "done_bytes": int(sum(b["sizeInBytes"] for b in sized)),
        "done_without_size": len(done) - len(sized),
        "oldest": started[0] if started else None,
        "newest": started[-1] if started else None,
    }


def print_service(sid, info, summary, warehouse, shared_with, date_range):
    print("service %s (%s)" % (info["name"] or "(no name)", sid))
    print("  backups: %d  (full %d, incremental %d)" % (
        summary["count"], summary["kinds"].get("full", 0), summary["kinds"].get("incremental", 0)))
    print("  status:  " + (", ".join("%s %d" % kv for kv in sorted(summary["states"].items(), key=lambda kv: str(kv[0]))) or "-"))
    print("  size of finished backups: %s (%d bytes)" % (human_bytes(summary["done_bytes"]), summary["done_bytes"]))
    if summary["done_without_size"]:
        print("  note: %d finished backup(s) have no sizeInBytes and are not in that sum" % summary["done_without_size"])
    print("  oldest startedAt: %s" % (summary["oldest"] or "-"))
    print("  newest startedAt: %s" % (summary["newest"] or "-"))
    if warehouse is None:
        print("  billed backupCHC: no datawarehouse row for warehouse %s in the loaded range" % (info["warehouse"] or "(unknown)"))
    else:
        days = len(warehouse["days"])
        print("  billed backupCHC on its data warehouse over %s: %.4f CHC in total, %.4f CHC per day (%d day(s))" % (
            date_range, warehouse["chc"], warehouse["chc"] / days if days else 0.0, days))
        if shared_with:
            print("  (this warehouse is shared with %d other service(s) in the data: the backupCHC is one figure for the warehouse)" % shared_with)
    print()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Backup size per service next to the billed backup CHC.")
    parser.add_argument("--out", metavar="DIR", help="output directory (default: out/ next to the scripts)")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    out_dir = args.out or chc_api.OUT_DIR
    jsonl_path = os.path.join(out_dir, "usage_cost.jsonl")

    if not os.path.exists(jsonl_path):
        print("%s not found: run 01-fetch.py first" % jsonl_path, file=sys.stderr)
        return 1
    rows = read_jsonl(jsonl_path)
    services, warehouses = services_and_backup_chc(rows)
    if not services:
        print("no service rows in usage_cost.jsonl; nothing to look up", file=sys.stderr)
        return 1
    days = sorted(r["date"] for r in rows)
    date_range = "%s .. %s" % (days[0], days[-1])

    config = chc_api.load_config(("CHC_ORG_ID",) + chc_api.API_VARS)
    per_warehouse = collections.Counter(info["warehouse"] for info in services.values())

    print("backups per service, next to the backupCHC billed in %s (CHC, not currency)" % date_range)
    print("the retained backups and the billed date range are different windows: older")
    print("backups may still exist, and backups taken in the range may be gone")
    print()
    not_found = 0
    for sid, info in services.items():
        try:
            backups, raw = fetch_backups(config["CHC_ORG_ID"], sid, config)
        except chc_api.ApiError as exc:
            if exc.status == 404:
                # Seen live: a service that is in the billing records can answer 404
                # on its backups (for example one that no longer exists). That is
                # no reason to skip the services after it.
                not_found += 1
                print("service %s (%s)" % (info["name"] or "(no name)", sid))
                print("  the backups API answers 404 (not found) for this service; no backups listed")
                print()
                continue
            if exc.status == 403:
                print("403: the API key lacks the permission control-plane:service:view-backups "
                      "(add the role Basic Service Reader, see .env.example)", file=sys.stderr)
            else:
                print("API error for service %s: %s" % (sid, exc), file=sys.stderr)
            return 1
        chc_api.write_private(
            os.path.join(out_dir, "backups_%s.json" % urllib.parse.quote(sid, safe="")),
            json.dumps(raw, indent=2) + "\n",
        )
        print_service(
            sid, info, summarize(backups), warehouses.get(info["warehouse"]),
            per_warehouse[info["warehouse"]] - 1, date_range,
        )
    if not_found:
        print("%d of %d service(s) answered 404 and are not in the summary above" % (not_found, len(services)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
