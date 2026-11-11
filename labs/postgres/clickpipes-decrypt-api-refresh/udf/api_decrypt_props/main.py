#!/usr/bin/env python3
"""api_decrypt_props(tenant_id String, props String) -> String

ClickHouse executable UDF (type executable, format JSONEachRow). ClickHouse starts it once per block, writes the
block's rows to stdin and closes it; this script sends the rows to the application's decrypt API in batches,
several batches at a time, and writes one {"result": "<decrypted properties as JSON text>"} line per input row,
in input order.

It holds no data key and no AWS credentials — only the API URL and a bearer token (config.json next to this
file; Cloud UDFs have no secret store yet). The API decides which properties stay encrypted.

Standard library only. A 401/403 fails at once; anything else is retried twice, then the block fails, the
refresh fails, and the next refresh retries the same rows.
"""
import concurrent.futures
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "config.json")) as f:
    CFG = json.load(f)
BATCH = int(CFG.get("batch", 500))
WORKERS = int(CFG.get("workers", 4))


def call(chunk):
    body = json.dumps({"rows": [{"tenant": r["tenant_id"], "props": r["props"]} for r in chunk]},
                      ensure_ascii=False).encode()
    req = urllib.request.Request(CFG["api_url"], data=body, method="POST",
                                 headers={"content-type": "application/json", "authorization": "Bearer " + CFG["token"]})
    last = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                out = json.load(r)["rows"]
            if len(out) != len(chunk):
                raise RuntimeError(f"decrypt API returned {len(out)} rows for {len(chunk)}")
            return out
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise RuntimeError(f"decrypt API refused the call: HTTP {e.code}") from None
            last = RuntimeError(f"decrypt API HTTP {e.code}")
        except Exception as e:  # timeouts, connection errors
            last = e
        time.sleep(0.5 * (attempt + 1))
    raise RuntimeError(f"decrypt API failed after 3 attempts: {last}")


def main():
    rows = [json.loads(line) for line in sys.stdin if line.strip()]
    chunks = [rows[i:i + BATCH] for i in range(0, len(rows), BATCH)]
    # The Cloud UDF sandbox caps threads (16 workers per process failed with "can't start new thread",
    # 2026-11-11, several processes run at once): keep a few, and go sequential if even those are refused.
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(WORKERS, len(chunks)) or 1) as ex:
            results = list(ex.map(call, chunks))
    except RuntimeError as e:
        if "can't start new thread" not in str(e):
            raise
        results = [call(c) for c in chunks]
    w = sys.stdout.write
    for part in results:
        for props in part:
            w(json.dumps({"result": json.dumps(props, ensure_ascii=False)}, ensure_ascii=False) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"api_decrypt_props: {e}", file=sys.stderr)
        sys.exit(1)
