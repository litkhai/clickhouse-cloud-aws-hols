#!/usr/bin/env python3
"""kms_unwrap(encrypted_data_key String) -> String

ClickHouse executable UDF (TabSeparated, one row per line). Each input row is a
base64 KMS ciphertext blob (an encrypted data key from GenerateDataKey). The
output row is the plaintext data key as hex, for the built-in decrypt():

    decrypt('aes-256-cbc', ciphertext, unhex(kms_unwrap(edk)), iv)

KMS is called once per distinct blob per process (executable_pool keeps the
process alive across blocks and queries), so one key per tenant costs one
Decrypt per pool process, not one per row.

Standard library only (SigV4 by hand), so the zip needs no requirements.txt.
Credentials come from config.json next to this file: Cloud UDFs have no cloud
identity and no secret store yet, so whatever is in config.json is what the
function can use. Give it a principal that may only call kms:Decrypt on one key.
"""
import base64
import datetime
import hashlib
import hmac
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "config.json")) as f:
    CFG = json.load(f)

REGION = CFG["region"]
HOST = f"kms.{REGION}.amazonaws.com"
CACHE = {}


def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def kms_decrypt(blob_b64):
    body = json.dumps({"CiphertextBlob": blob_b64}).encode()
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    day = now.strftime("%Y%m%d")
    headers = {
        "content-type": "application/x-amz-json-1.1",
        "host": HOST,
        "x-amz-date": amz_date,
        "x-amz-target": "TrentService.Decrypt",
    }
    if CFG.get("session_token"):
        headers["x-amz-security-token"] = CFG["session_token"]
    names = sorted(headers)
    canonical = "\n".join([
        "POST", "/", "",
        "".join(f"{n}:{headers[n]}\n" for n in names),
        ";".join(names),
        hashlib.sha256(body).hexdigest(),
    ])
    scope = f"{day}/{REGION}/kms/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                         hashlib.sha256(canonical.encode()).hexdigest()])
    k = _sign(("AWS4" + CFG["secret_access_key"]).encode(), day)
    for part in (REGION, "kms", "aws4_request"):
        k = _sign(k, part)
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={CFG['access_key_id']}/{scope}, "
        f"SignedHeaders={';'.join(names)}, Signature={sig}")
    req = urllib.request.Request(f"https://{HOST}/", data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return base64.b64decode(json.load(r)["Plaintext"]).hex()


for line in sys.stdin:
    blob = line.rstrip("\n")
    if not blob:  # e.g. a row without a key: return a dummy key instead of failing the block
        sys.stdout.write("00" * 32 + "\n")
        sys.stdout.flush()
        continue
    key = CACHE.get(blob)
    if key is None:
        key = kms_decrypt(blob)
        CACHE[blob] = key
    sys.stdout.write(key + "\n")
    sys.stdout.flush()
