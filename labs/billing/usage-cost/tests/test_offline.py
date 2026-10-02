#!/usr/bin/env python3
"""Offline tests for the usage-cost lab: no network, no ClickHouse service.

    python3 labs/billing/usage-cost/tests/test_offline.py

Plain Python, no pytest. It covers the date windows, 01-fetch.py (including fault
injection: each check must fail on a record built to break it), the HTTP helper
with a faked urlopen, 04-backups.py with a faked API, and, when a `clickhouse`
binary is on PATH, 02-load.sql and 03-allocate.sql run through `clickhouse local`
against made-up data. The SQL part is skipped, and says so, without the binary.

Everything is made up: tests/fixtures/*.json and tests/fixtures/fake_system.sql.
Nothing here reads .env or ~/.config, and nothing calls the API.
"""
import contextlib
import copy
import datetime
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import traceback
import urllib.error
from email.message import Message
from unittest import mock

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(TESTS_DIR)
FIXTURES = os.path.join(TESTS_DIR, "fixtures")
USAGE_FIXTURE = os.path.join(FIXTURES, "usage_cost_response.json")
BACKUPS_FIXTURE = os.path.join(FIXTURES, "backups_response.json")
FAKE_SYSTEM_SQL = os.path.join(FIXTURES, "fake_system.sql")

sys.path.insert(0, LAB)
import chc_api  # noqa: E402

SERVICE_A = "00000000-0000-4000-8000-000000000002"
D = datetime.date


def load_script(module_name, filename):
    """Import a script whose file name is not a valid module name (01-fetch.py)."""
    spec = importlib.util.spec_from_file_location(module_name, os.path.join(LAB, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path, document):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)


def read_text(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def run_fetch(*args):
    """01-fetch.py in a subprocess -> (exit code, stdout, stderr)."""
    done = subprocess.run(
        [sys.executable, os.path.join(LAB, "01-fetch.py")] + list(args),
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60,
    )
    return done.returncode, done.stdout, done.stderr


def read_jsonl(path):
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


class Tmp:
    """A temporary directory that is removed afterwards."""

    def __enter__(self):
        self.path = tempfile.mkdtemp(prefix="usage-cost-test-")
        return self.path

    def __exit__(self, *exc):
        shutil.rmtree(self.path, ignore_errors=True)


def mutated_fixture(tmp, name, mutate):
    document = read_json(USAGE_FIXTURE)
    mutate(document)
    path = os.path.join(tmp, name)
    write_json(path, document)
    return path


# --- windows ------------------------------------------------------------------

def test_windows_split_across_two_windows():
    assert chc_api.windows(D(2026, 8, 21), D(2026, 10, 1)) == [
        (D(2026, 8, 21), D(2026, 9, 20)),
        (D(2026, 9, 21), D(2026, 10, 1)),
    ]


def test_windows_31_days_is_one_window():
    assert chc_api.windows(D(2026, 8, 21), D(2026, 9, 20)) == [(D(2026, 8, 21), D(2026, 9, 20))]


def test_windows_32_days_is_two_windows():
    assert chc_api.windows(D(2026, 8, 21), D(2026, 9, 21)) == [
        (D(2026, 8, 21), D(2026, 9, 20)),
        (D(2026, 9, 21), D(2026, 9, 21)),
    ]


def test_windows_one_day_is_one_window():
    assert chc_api.windows(D(2026, 10, 1), D(2026, 10, 1)) == [(D(2026, 10, 1), D(2026, 10, 1))]


def test_windows_accepts_strings():
    assert chc_api.windows("2026-10-01", "2026-10-01") == [(D(2026, 10, 1), D(2026, 10, 1))]


def test_windows_rejects_from_after_to():
    try:
        chc_api.windows(D(2026, 10, 2), D(2026, 10, 1))
    except ValueError:
        return
    raise AssertionError("from > to was accepted")


# --- 01-fetch.py ----------------------------------------------------------------

def test_fetch_from_fixture_succeeds():
    with Tmp() as tmp:
        code, out, err = run_fetch("--input", USAGE_FIXTURE, "--out", tmp)
        assert code == 0, (code, out, err)
        rows = read_jsonl(os.path.join(tmp, "usage_cost.jsonl"))
        assert len(rows) == 12, len(rows)
        assert "CHC" in out and "not currency" in out
        assert "provisional days (locked=false)" in out and "2026-10-01" in out
        assert "grand total:  195.2000 CHC" in out, out
        warehouse = [r for r in rows if r["entityType"] == "datawarehouse"][0]
        assert warehouse["serviceId"] == "", warehouse           # null -> ""
        assert warehouse["storageCHC"] == 10.0 and warehouse["computeCHC"] == 0.0
        assert warehouse["locked"] is True
        assert [r for r in rows if not r["locked"]] and all(r["date"] == "2026-10-01" for r in rows if not r["locked"])
        assert re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}$", rows[0]["fetched_at"]), rows[0]["fetched_at"]
        assert not any(key.startswith("_") for key in rows[0])
        assert set(rows[0]) == {
            "date", "entityType", "entityId", "entityName", "serviceId", "dataWarehouseId",
            "organizationTier", "locked", "totalCHC", "fetched_at",
        } | set(load_script("fetch_mod", "01-fetch.py").METRIC_COLUMNS)


def test_fault_metric_from_the_wrong_entity_type_fails_and_is_named():
    def mutate(document):
        first_service = [c for c in document["result"]["costs"] if c["entityType"] == "service"][0]
        first_service["metrics"]["storageCHC"] = 0.0
    with Tmp() as tmp:
        bad = mutated_fixture(tmp, "bad.json", mutate)
        out_dir = os.path.join(tmp, "out")
        code, out, err = run_fetch("--input", bad, "--out", out_dir)
        assert code != 0, (code, out, err)
        text = out + err
        assert "storageCHC" in text and "service" in text and "2026-09-29" in text, text
        assert "00000000-0000-4000-8000-000000000002" in text, text
        assert not os.path.exists(os.path.join(out_dir, "usage_cost.jsonl"))


def test_fault_grand_total_mismatch_fails():
    def mutate(document):
        document["result"]["grandTotalCHC"] += 1.0
    with Tmp() as tmp:
        bad = mutated_fixture(tmp, "bad.json", mutate)
        code, out, err = run_fetch("--input", bad, "--out", os.path.join(tmp, "out"))
        assert code != 0, (code, out, err)
        assert "grandTotalCHC" in out + err


def test_fault_unknown_entity_type_fails():
    def mutate(document):
        document["result"]["costs"][0]["entityType"] = "mystery"
    with Tmp() as tmp:
        bad = mutated_fixture(tmp, "bad.json", mutate)
        code, out, err = run_fetch("--input", bad, "--out", os.path.join(tmp, "out"))
        assert code != 0, (code, out, err)
        assert "mystery" in out + err


def test_failure_removes_a_stale_jsonl():
    def mutate(document):
        document["result"]["grandTotalCHC"] += 1.0
    with Tmp() as tmp:
        out_dir = os.path.join(tmp, "out")
        assert run_fetch("--input", USAGE_FIXTURE, "--out", out_dir)[0] == 0
        stale = os.path.join(out_dir, "usage_cost.jsonl")
        assert os.path.exists(stale)
        bad = mutated_fixture(tmp, "bad.json", mutate)
        assert run_fetch("--input", bad, "--out", out_dir)[0] != 0
        assert not os.path.exists(stale), "a failed run left the earlier jsonl in place"


def test_informational_lines_do_not_fail():
    def mutate(document):
        record = document["result"]["costs"][1]          # a service record
        record["totalCHC"] += 1.0                          # no longer equals its metrics
        document["result"]["grandTotalCHC"] += 1.0         # but the window total still adds up
        del document["result"]["costs"][2]["metrics"]["publicDataTransferCHC"]
        document["result"]["costs"][3]["serviceId"] = None  # a clickpipe record without serviceId
    with Tmp() as tmp:
        odd = mutated_fixture(tmp, "odd.json", mutate)
        out_dir = os.path.join(tmp, "out")
        code, out, err = run_fetch("--input", odd, "--out", out_dir)
        assert code == 0, (code, out, err)
        assert "sum(metrics) != totalCHC: 2 of 12" in out, out
        assert "serviceId is null iff datawarehouse': 1" in out, out
        row = [r for r in read_jsonl(os.path.join(out_dir, "usage_cost.jsonl")) if r["entityName"] == "service-b"][0]
        assert row["publicDataTransferCHC"] == 0.0          # absent -> 0


def test_two_input_files_are_two_windows():
    with Tmp() as tmp:
        code, out, err = run_fetch("--input", USAGE_FIXTURE, USAGE_FIXTURE, "--out", tmp)
        assert code == 0, (code, out, err)
        assert "windows:      2" in out and "records:      24" in out, out
        assert "duplicate (date, entityType, entityId) keys: 12" in out, out


def test_input_cannot_be_combined_with_a_range():
    code, out, err = run_fetch("--input", USAGE_FIXTURE, "--from", "2026-09-01", "--to", "2026-09-02")
    assert code == 2, (code, out, err)


def test_range_is_required_without_input():
    code, out, err = run_fetch()
    assert code == 2, (code, out, err)


# --- chc_api: configuration and HTTP ------------------------------------------------

def test_load_config_environment_wins_and_env_file_fills_in():
    with Tmp() as tmp:
        env_file = os.path.join(tmp, ".env")
        with open(env_file, "w") as handle:
            handle.write("# comment\n\nCHC_ORG_ID=from-file\nCHC_API_KEY_ID='quoted-id'\nCHC_API_KEY_SECRET=\"quoted-secret\"\n")
        with mock.patch.dict(os.environ, {"CHC_ORG_ID": "from-env"}):
            config = chc_api.load_config(("CHC_ORG_ID", "CHC_API_KEY_ID", "CHC_API_KEY_SECRET"), env_file=env_file)
        assert config == {"CHC_ORG_ID": "from-env", "CHC_API_KEY_ID": "quoted-id", "CHC_API_KEY_SECRET": "quoted-secret"}, config


def test_load_config_missing_names_only_the_variable():
    with Tmp() as tmp:
        env_file = os.path.join(tmp, ".env")
        with open(env_file, "w") as handle:
            handle.write("CHC_API_KEY_ID=an-id\nCHC_API_KEY_SECRET=<placeholder-secret>\n")
        with mock.patch.dict(os.environ, {}, clear=True):
            try:
                chc_api.load_config(("CHC_ORG_ID", "CHC_API_KEY_ID", "CHC_API_KEY_SECRET"), env_file=env_file)
            except SystemExit as exc:
                message = str(exc)
            else:
                raise AssertionError("missing configuration was accepted")
    assert "CHC_ORG_ID" in message and "CHC_API_KEY_SECRET" in message, message
    assert "an-id" not in message and "placeholder-secret" not in message, message


class FakeResponse:
    def __init__(self, document):
        self._body = json.dumps(document).encode("utf-8")

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(code, document):
    return urllib.error.HTTPError("https://example.invalid/", code, "x", Message(), io.BytesIO(json.dumps(document).encode("utf-8")))


API_CONFIG = {"CHC_API_KEY_ID": "test-key-id", "CHC_API_KEY_SECRET": "test-key-secret"}


def test_api_get_sends_basic_auth_and_repeated_filter_params():
    seen = []

    def fake_urlopen(request, timeout=None):
        seen.append(request)
        return FakeResponse({"status": 200, "result": {}})

    with mock.patch("chc_api.urllib.request.urlopen", fake_urlopen):
        chc_api.api_get("/v1/x", [("from_date", "2026-09-01"), ("filter", "tag:A=1"), ("filter", "tag:B=2")], config=API_CONFIG)
        chc_api.api_get("/v1/x", {"filter": ["tag:A=1", "tag:B=2"]}, config=API_CONFIG)
    for request in seen:
        query = chc_api.urllib.parse.parse_qs(chc_api.urllib.parse.urlsplit(request.full_url).query)
        assert query["filter"] == ["tag:A=1", "tag:B=2"], query
    import base64
    expected = "Basic " + base64.b64encode(b"test-key-id:test-key-secret").decode()
    assert seen[0].get_header("Authorization") == expected


def test_api_get_retries_429_then_succeeds():
    answers = [http_error(429, {"error": "slow down"}), http_error(503, {"error": "busy"}), FakeResponse({"status": 200, "result": {"ok": 1}})]
    sleeps = []

    def fake_urlopen(request, timeout=None):
        answer = answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer

    with mock.patch("chc_api.urllib.request.urlopen", fake_urlopen), mock.patch("chc_api.time.sleep", sleeps.append):
        assert chc_api.api_get("/v1/x", config=API_CONFIG)["result"] == {"ok": 1}
    assert len(sleeps) == 2 and sleeps[1] > sleeps[0], sleeps


def test_api_get_gives_up_after_the_last_try_on_5xx():
    calls = []

    def fake_urlopen(request, timeout=None):
        calls.append(1)
        raise http_error(500, {"error": "boom"})

    with mock.patch("chc_api.urllib.request.urlopen", fake_urlopen), mock.patch("chc_api.time.sleep", lambda s: None):
        try:
            chc_api.api_get("/v1/x", config=API_CONFIG)
        except chc_api.ApiError as exc:
            assert exc.status == 500 and "boom" in str(exc)
        else:
            raise AssertionError("no error raised")
    assert len(calls) == chc_api.MAX_TRIES, calls


def test_api_get_400_carries_the_api_error_text_and_no_secret():
    text = "BAD_REQUEST: Time period queried exceeds 31 days"
    calls = []

    def fake_urlopen(request, timeout=None):
        calls.append(1)
        raise http_error(400, {"status": 400, "error": text})

    with mock.patch("chc_api.urllib.request.urlopen", fake_urlopen), mock.patch("chc_api.time.sleep", lambda s: None):
        try:
            chc_api.api_get("/v1/x", config=API_CONFIG)
        except chc_api.ApiError as exc:
            message = str(exc)
            assert exc.status == 400 and text in message, message
            assert "test-key-secret" not in message and "test-key-id" not in message and "Basic" not in message, message
        else:
            raise AssertionError("no error raised")
    assert len(calls) == 1, "a 400 must not be retried"


# --- 04-backups.py ----------------------------------------------------------------

def run_backups(tmp, api_get):
    backups = load_script("backups_mod", "04-backups.py")
    out, err = io.StringIO(), io.StringIO()
    env = {"CHC_ORG_ID": "org-test", "CHC_API_KEY_ID": "id-test", "CHC_API_KEY_SECRET": "secret-test"}
    with mock.patch.dict(os.environ, env), mock.patch("chc_api.api_get", api_get), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = backups.main(["--out", tmp])
    return code, out.getvalue(), err.getvalue()


def test_backups_summary_next_to_billed_backup_chc():
    paths = []

    def fake_api_get(path, params=None, config=None):
        paths.append(path)
        return read_json(BACKUPS_FIXTURE)

    with Tmp() as tmp:
        assert run_fetch("--input", USAGE_FIXTURE, "--out", tmp)[0] == 0
        code, out, err = run_backups(tmp, fake_api_get)
        assert code == 0, (code, out, err)
        assert paths[0] == "/v1/organizations/org-test/services/%s/backups" % SERVICE_A, paths
        assert "backups: 4  (full 1, incremental 3)" in out, out
        assert "size of finished backups: 1.00 GiB (1075838976 bytes)" in out, out
        assert "oldest startedAt: 2026-09-28T06:00:00.000Z" in out and "newest startedAt: 2026-10-01T06:00:00.000Z" in out, out
        assert "3.2500 CHC in total, 1.0833 CHC per day (3 day(s))" in out, out
        assert "different windows" in out
        assert "shared with 1 other service(s)" in out, out
        assert os.path.exists(os.path.join(tmp, "backups_%s.json" % SERVICE_A))


def test_backups_403_names_the_missing_permission_and_fails():
    def fake_api_get(path, params=None, config=None):
        raise chc_api.ApiError(403, "forbidden")

    with Tmp() as tmp:
        assert run_fetch("--input", USAGE_FIXTURE, "--out", tmp)[0] == 0
        code, out, err = run_backups(tmp, fake_api_get)
        assert code != 0, (code, out, err)
        assert "control-plane:service:view-backups" in err, err
        assert "secret-test" not in out + err


def test_backups_404_for_one_service_does_not_stop_the_others():
    """Seen live: a billed service can answer 404 on its backups. The services after
    it must still be summarised; any other error still stops the run."""
    calls = []

    def fake_api_get(path, params=None, config=None):
        calls.append(path)
        if path.endswith("/00000000-0000-4000-8000-000000000002/backups"):
            raise chc_api.ApiError(404, "NOT_FOUND: gone")
        return read_json(BACKUPS_FIXTURE)

    with Tmp() as tmp:
        assert run_fetch("--input", USAGE_FIXTURE, "--out", tmp)[0] == 0
        code, out, err = run_backups(tmp, fake_api_get)
        assert code == 0, (code, out, err)
        assert len(calls) == 2, calls                     # service-a (404) and service-b were both asked
        assert "answers 404" in out and "1 of 2 service(s) answered 404" in out, out
        assert "backups: 4  (full 1, incremental 3)" in out, out    # service-b still summarised
        assert not os.path.exists(os.path.join(tmp, "backups_%s.json" % SERVICE_A))


def test_backups_other_errors_still_stop_the_run():
    def fake_api_get(path, params=None, config=None):
        raise chc_api.ApiError(500, "boom")

    with Tmp() as tmp:
        assert run_fetch("--input", USAGE_FIXTURE, "--out", tmp)[0] == 0
        code, out, err = run_backups(tmp, fake_api_get)
        assert code != 0 and "boom" in err, (code, out, err)


# --- 02-load.sql and 03-allocate.sql through clickhouse local ----------------------

def clickhouse_available():
    return shutil.which("clickhouse") is not None


def run_clickhouse(sql_path, cwd, *params):
    done = subprocess.run(
        ["clickhouse", "local", "--queries-file", sql_path] + list(params),
        cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180,
    )
    return done.returncode, done.stdout, done.stderr


def sql_text(name):
    return read_text(os.path.join(LAB, name))


def prepare_workdir(tmp):
    """tmp/out/usage_cost.jsonl from the fixture, as 01-fetch.py writes it."""
    assert run_fetch("--input", USAGE_FIXTURE, "--out", os.path.join(tmp, "out"))[0] == 0


def test_load_sql_loads_and_example_queries_run():
    with Tmp() as tmp:
        prepare_workdir(tmp)
        script = os.path.join(tmp, "run.sql")
        # Re-fetch of the provisional day 2026-10-01 with a later fetched_at and a new
        # value: ReplacingMergeTree must keep one row per key, the newer one.
        rows = read_jsonl(os.path.join(tmp, "out", "usage_cost.jsonl"))
        with open(os.path.join(tmp, "out", "second.jsonl"), "w") as handle:
            for row in rows:
                if row["date"] == "2026-10-01" and row["entityName"] == "service-a":
                    row = dict(row, computeCHC=99.0, fetched_at="2099-01-01 00:00:00.000")
                    handle.write(json.dumps(row) + "\n")
        with open(script, "w") as handle:
            handle.write(sql_text("02-load.sql"))
            handle.write(
                "INSERT INTO billing_hols.usage_cost FROM INFILE 'out/second.jsonl' FORMAT JSONEachRow;\n"
                "SELECT throwIf(count() != 12, 'FINAL must still show 12 rows') FROM billing_hols.usage_cost FINAL FORMAT Null;\n"
                "SELECT throwIf(sumIf(computeCHC, entityName = 'service-a' AND date = '2026-10-01') != 99, 'the newer fetch must win') "
                "FROM billing_hols.usage_cost FINAL FORMAT Null;\n"
            )
        code, out, err = run_clickhouse(script, tmp)
        assert code == 0, (code, out, err)
        assert "datawarehouse" in out and "30.75" in out and "3.25" in out, out         # Q1a / Q1b
        assert "warehouse-a" in out and "provisional" in out and "inter-region tier 4" in out, out  # Q1b / Q2


def test_load_sql_guard_fires_on_a_foreign_database_and_not_on_our_own():
    with Tmp() as tmp:
        prepare_workdir(tmp)
        for label, setup, should_fail in (
            ("foreign comment", "CREATE DATABASE billing_hols COMMENT 'someone else';\n", True),
            ("no comment", "CREATE DATABASE billing_hols;\n", True),
            ("our own comment (control)", "CREATE DATABASE billing_hols COMMENT 'clickhouse-cloud-aws-hols labs/billing/usage-cost';\n", False),
            ("clean server (control)", "", False),
        ):
            script = os.path.join(tmp, "guard.sql")
            with open(script, "w") as handle:
                handle.write(setup + sql_text("02-load.sql"))
            code, out, err = run_clickhouse(script, tmp)
            if should_fail:
                assert code != 0 and "refusing to write to it" in err, (label, code, err)
                assert "datawarehouse" not in out, (label, "queries ran after the guard fired")
            else:
                assert code == 0, (label, code, err)


def point_03_at_fixture(sql, tail=""):
    """03 reads system.* through clusterAllReplicas('default', merge('system', ...)),
    which clickhouse local cannot do. Swap the three sources for the fx tables and
    insist that every swap happened (a silent no-op would test nothing)."""
    sql, logs = re.subn(r"clusterAllReplicas\('default',\s*merge\('system',\s*('[^']*')\)\)", r"merge('fx', \1)", sql)
    assert logs == 2, "expected the two merge() sources in 03-allocate.sql, found %d" % logs
    sql, parts = re.subn(r"\bFROM system\.parts\b", "FROM fx.parts", sql)
    assert parts == 1, "expected one FROM system.parts in 03-allocate.sql, found %d" % parts
    return sql + tail


def expect(label, scalar_sql, expected):
    if isinstance(expected, str):
        return "SELECT throwIf((%s) != '%s', 'expected %s') FORMAT Null;\n" % (scalar_sql, expected, label)
    return "SELECT throwIf(abs((%s) - %r) > 1e-9, 'expected %s = %r') FORMAT Null;\n" % (scalar_sql, expected, label, expected)


def expected_allocation_checks():
    cpu = "SELECT sum(allocated_chc) FROM tmp_alloc_user WHERE user = '%s' AND day = '%s'"
    day = "SELECT %s FROM tmp_day WHERE day = '%s'"
    store = "SELECT sum(allocated_chc) FROM tmp_alloc_storage WHERE database = '%s'"
    return "".join([
        # 2026-09-29: capacity 4800 core-s, cpu 1200 s, 40 CHC billed -> 25% allocated
        expect("capacity day1", day % ("capacity_s", "2026-09-29"), 4800.0),
        expect("replicas day1", day % ("replicas", "2026-09-29"), 2),
        expect("alice day1", cpu % ("alice", "2026-09-29"), 7.5),
        expect("bob day1", cpu % ("bob", "2026-09-29"), 2.5),
        expect("unallocated day1", day % ("compute_unallocated", "2026-09-29"), 30.0),
        expect("flag day1", day % ("flag", "2026-09-29"), ""),
        # 2026-09-30: cpu 6000 s above capacity 4800 -> scaled down, everything allocated
        expect("alice day2", cpu % ("alice", "2026-09-30"), 36.0),
        expect("bob day2", cpu % ("bob", "2026-09-30"), 12.0),
        expect("unallocated day2", day % ("compute_unallocated", "2026-09-30"), 0.0),
        expect("flag day2", day % ("flag", "2026-09-30"), "cpu above capacity: shares scaled down"),
        # 2026-10-01: no capacity samples -> entirely unallocated, flagged
        expect("carol day3", cpu % ("carol", "2026-10-01"), 0.0),
        expect("unallocated day3", day % ("compute_unallocated", "2026-10-01"), 24.0),
        expect("flag day3", day % ("flag", "2026-10-01"), "no system log"),
        # storage: db_a 600, db_b 300, system 100 active bytes; 10 + 10.5 + 10.25 CHC billed
        expect("db_a storage", store % "db_a", 0.6 * 30.75),
        expect("db_b storage", store % "db_b", 0.3 * 30.75),
        expect("system storage", store % "system", 0.1 * 30.75),
    ])


def run_allocation(tmp, tail="", sql_edit=None, service_id=SERVICE_A):
    prepare_workdir(tmp)
    script = os.path.join(tmp, "allocate.sql")
    allocate = point_03_at_fixture(sql_text("03-allocate.sql"))
    if sql_edit is not None:
        allocate = sql_edit(allocate)
    with open(script, "w") as handle:
        handle.write(read_text(FAKE_SYSTEM_SQL) + "\n" + sql_text("02-load.sql") + "\n" + allocate + "\n" + tail)
    return run_clickhouse(
        script, tmp, "--param_service_id=" + service_id, "--param_from=2026-09-29", "--param_to=2026-10-01"
    )


def test_allocate_sql_numbers_and_flags():
    with Tmp() as tmp:
        code, out, err = run_allocation(tmp, tail=expected_allocation_checks())
        assert code == 0, (code, out, err)
        assert "ALLOCATION, NOT A BILL" in out, out
        assert "unallocated: idle uptime, merges, background work" in out, out
        assert "includes 1 day(s) flagged no system log" in out, out
        assert "no system log" in out and "cpu above capacity" in out, out
        assert "check ok: on every one of 3 day(s)" in out, out
        assert "mallory" not in out, "the decoy table query_log_copy was read"
        assert "alice" in out and "bob" in out and "db_a" in out and "total" in out, out


def test_allocate_sql_fault_no_active_parts_fails_the_check():
    with Tmp() as tmp:
        code, out, err = run_allocation_with_empty_parts(tmp)
        assert code != 0, (code, out, err)
        assert "billed CHC differs from allocated + unallocated" in err, err
        assert "check ok" not in out


def run_allocation_with_empty_parts(tmp):
    prepare_workdir(tmp)
    script = os.path.join(tmp, "allocate.sql")
    allocate = point_03_at_fixture(sql_text("03-allocate.sql"))
    with open(script, "w") as handle:
        handle.write(
            read_text(FAKE_SYSTEM_SQL) + "\nTRUNCATE TABLE fx.parts;\n" + sql_text("02-load.sql") + "\n" + allocate
        )
    return run_clickhouse(script, tmp, "--param_service_id=" + SERVICE_A, "--param_from=2026-09-29", "--param_to=2026-10-01")


def test_allocate_sql_fault_overwide_log_pattern_is_caught_by_the_expected_numbers():
    """Control for the checks above: widen the table pattern so the decoy is read,
    and the expected numbers must stop holding."""
    def widen(sql):
        assert sql.count("(_[0-9]+)?$") >= 2
        return sql.replace("^query_log(_[0-9]+)?$", "^query_log")
    with Tmp() as tmp:
        code, out, err = run_allocation(tmp, tail=expected_allocation_checks(), sql_edit=widen)
        assert code != 0 and "expected" in err, (code, out, err)


def test_allocate_sql_unknown_service_stops_at_the_guard():
    with Tmp() as tmp:
        code, out, err = run_allocation(tmp, service_id="00000000-0000-4000-8000-0000000000ff")
        assert code != 0 and "no service rows in billing_hols.usage_cost" in err, (code, out, err)


def test_sql_files_write_only_to_billing_hols():
    for name in ("02-load.sql", "03-allocate.sql"):
        text = re.sub(r"--[^\n]*", "", sql_text(name))
        for statement in re.findall(r"(?is)\b(?:CREATE\s+(?:TEMPORARY\s+)?TABLE(?:\s+IF\s+NOT\s+EXISTS)?|INSERT\s+INTO|CREATE\s+DATABASE(?:\s+IF\s+NOT\s+EXISTS)?)\s+([A-Za-z0-9_.`]+)", text):
            assert statement.startswith("billing_hols") or statement.startswith("tmp_"), (name, statement)


# --- runner -------------------------------------------------------------------------

SQL_TESTS = {
    "test_load_sql_loads_and_example_queries_run",
    "test_load_sql_guard_fires_on_a_foreign_database_and_not_on_our_own",
    "test_allocate_sql_numbers_and_flags",
    "test_allocate_sql_fault_no_active_parts_fails_the_check",
    "test_allocate_sql_fault_overwide_log_pattern_is_caught_by_the_expected_numbers",
    "test_allocate_sql_unknown_service_stops_at_the_guard",
}


def main():
    tests = [(name, fn) for name, fn in sorted(globals().items()) if name.startswith("test_") and callable(fn)]
    failed, skipped = [], []
    for name, fn in tests:
        if name in SQL_TESTS and not clickhouse_available():
            skipped.append(name)
            print("skip  %s (no clickhouse binary on PATH)" % name)
            continue
        try:
            fn()
        except Exception:
            failed.append(name)
            print("FAIL  %s" % name)
            traceback.print_exc(file=sys.stdout)
        else:
            print("ok    %s" % name)
    print("\n%d run, %d failed, %d skipped" % (len(tests) - len(skipped), len(failed), len(skipped)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
