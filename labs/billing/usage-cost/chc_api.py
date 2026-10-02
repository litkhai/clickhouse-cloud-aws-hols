"""Shared helpers for the usage-cost lab: configuration, HTTP and date windows.

Standard library only (Python 3.9+). Used by 01-fetch.py and 04-backups.py.

Nothing here prints, logs or stores the API key. Error messages carry the HTTP
status and the API's own error text, never a request header.
"""
import base64
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = "https://api.clickhouse.cloud"

# Every path is derived from this file, so the lab works from any checkout.
LAB_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = os.path.join(LAB_DIR, ".env")
# Raw responses and the flattened records. gitignored: real names, ids and
# amounts live here. 01-fetch.py and 04-backups.py take --out to override it.
OUT_DIR = os.path.join(LAB_DIR, "out")

API_VARS = ("CHC_API_KEY_ID", "CHC_API_KEY_SECRET")
TIMEOUT_S = 30
MAX_TRIES = 4          # one call plus three retries
BACKOFF_S = 1.0        # doubled after each retry: 1 s, 2 s, 4 s
RETRY_AFTER_CAP_S = 30


class ApiError(Exception):
    """An HTTP error answered by the API (status None: no answer at all)."""

    def __init__(self, status, message):
        super().__init__("HTTP %s: %s" % (status, message))
        self.status = status
        self.message = message


# --- configuration ----------------------------------------------------------

def _parse_env_file(path):
    """KEY=VALUE lines; blank lines and full-line comments ignored; one pair
    of surrounding quotes stripped. No inline comments (a secret may hold '#')."""
    values = {}
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        return values
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def _is_placeholder(value):
    return value.startswith("<") and value.endswith(">")


def load_config(required, env_file=None):
    """Return {name: value} for each name in `required`.

    The process environment wins; otherwise the value comes from `.env` next to
    the scripts. A variable that is missing, empty or still the `<placeholder>`
    from .env.example ends the run with a message that names the variable only.
    """
    from_file = _parse_env_file(env_file or ENV_FILE)
    config, missing = {}, []
    for name in required:
        value = os.environ.get(name) or from_file.get(name) or ""
        if not value or _is_placeholder(value):
            missing.append(name)
        else:
            config[name] = value
    if missing:
        sys.exit(
            "missing configuration: %s\n"
            "set it in the environment or in .env next to the scripts "
            "(copy .env.example)" % ", ".join(missing)
        )
    return config


# --- HTTP -------------------------------------------------------------------

def _error_text(body):
    """The API's `error` text, or a short excerpt when the body is not JSON."""
    text = body.decode("utf-8", errors="replace")
    try:
        parsed = json.loads(text)
    except ValueError:
        return text.strip()[:200] or "(empty body)"
    if isinstance(parsed, dict) and parsed.get("error"):
        return str(parsed["error"])
    return text.strip()[:200] or "(empty body)"


def _retry_delay(exc, fallback):
    value = exc.headers.get("Retry-After") if exc.headers else None
    if value and value.strip().isdigit():
        return min(int(value.strip()), RETRY_AFTER_CAP_S)
    return fallback


def api_get(path, params=None, config=None):
    """GET BASE_URL + path with HTTP Basic auth; return the parsed JSON.

    `params` is a dict or a list of pairs; a list value becomes repeated
    parameters (`filter=a&filter=b`). Retries 429 and 5xx with backoff.
    Any other HTTP error raises ApiError(status, API error text).
    """
    if config is None:
        config = load_config(API_VARS)
    url = BASE_URL + path
    if params:
        url += "?" + urllib.parse.urlencode(params, doseq=True)
    credentials = "%s:%s" % (config["CHC_API_KEY_ID"], config["CHC_API_KEY_SECRET"])
    token = base64.b64encode(credentials.encode("utf-8")).decode("ascii")
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": "Basic " + token,
            "Accept": "application/json",
            "User-Agent": "clickhouse-cloud-aws-hols/usage-cost",
        },
    )
    delay = BACKOFF_S
    for attempt in range(1, MAX_TRIES + 1):
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
                body = response.read()
        except urllib.error.HTTPError as exc:
            status = exc.code
            try:
                error_body = exc.read()
            except Exception:  # an unreadable error body must not hide the status
                error_body = b""
            if (status == 429 or status >= 500) and attempt < MAX_TRIES:
                time.sleep(_retry_delay(exc, delay))
                delay *= 2
                continue
            raise ApiError(status, _error_text(error_body))
        except urllib.error.URLError as exc:
            raise ApiError(None, "network error: %s" % (exc.reason,))
        try:
            return json.loads(body.decode("utf-8"))
        except ValueError:
            raise ApiError(200, "response body is not JSON")
    raise ApiError(None, "gave up after %d tries" % MAX_TRIES)  # not reached


# --- dates ------------------------------------------------------------------

def parse_date(text):
    """'YYYY-MM-DD' -> datetime.date (ValueError otherwise)."""
    return datetime.datetime.strptime(text, "%Y-%m-%d").date()


def _as_date(value):
    return value if isinstance(value, datetime.date) else parse_date(value)


def windows(from_date, to_date, max_days=31):
    """Split the inclusive range into inclusive windows of at most `max_days`
    calendar days (the API rejects more than 31). Dates may be date objects or
    'YYYY-MM-DD' strings. Raises ValueError when from_date is after to_date."""
    start, end = _as_date(from_date), _as_date(to_date)
    if max_days < 1:
        raise ValueError("max_days must be at least 1")
    if start > end:
        raise ValueError("from_date %s is after to_date %s" % (start, end))
    one_day = datetime.timedelta(days=1)
    result, cursor = [], start
    while cursor <= end:
        last = min(cursor + datetime.timedelta(days=max_days) - one_day, end)
        result.append((cursor, last))
        cursor = last + one_day
    return result


# --- files ------------------------------------------------------------------

def write_private(path, text):
    """Write `text` to `path`, creating the file with mode 600 (out/ holds real
    names and amounts)."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(text)
