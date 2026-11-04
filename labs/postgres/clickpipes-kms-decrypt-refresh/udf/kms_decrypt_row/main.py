#!/usr/bin/env python3
"""kms_decrypt_row(edk String, email_enc String, phone_enc String, properties String) -> String

ClickHouse executable UDF, format JSONEachRow (one JSON object per row in, one out).
Returns a JSON string {"email": …, "phone": …, "properties": {…}} with every
"enc:v1:<base64(iv || AES-256-CBC)>" value decrypted and every property value as a string.

The data key never leaves this process: KMS Decrypt unwraps `edk` once per distinct value
(cached for the life of the executable_pool process) and the AES runs here, so SQL only
ever sees plaintext of ciphertext it already passed in — never a key.

Credentials come from config.json next to this file (Cloud UDFs have no cloud identity and
no secret store yet). Give it a principal that may only call kms:Decrypt on one key.
"""
import base64
import datetime
import hashlib
import hmac
import json
import os
import sys
import urllib.request

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "config.json")) as f:
    CFG = json.load(f)
REGION = CFG["region"]
HOST = f"kms.{REGION}.amazonaws.com"
KEYS = {}
PREFIX = "enc:v1:"


def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def kms_decrypt(blob_b64):
    body = json.dumps({"CiphertextBlob": blob_b64}).encode()
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    headers = {"content-type": "application/x-amz-json-1.1", "host": HOST,
               "x-amz-date": amz_date, "x-amz-target": "TrentService.Decrypt"}
    if CFG.get("session_token"):
        headers["x-amz-security-token"] = CFG["session_token"]
    names = sorted(headers)
    canonical = "\n".join(["POST", "/", "", "".join(f"{n}:{headers[n]}\n" for n in names),
                           ";".join(names), hashlib.sha256(body).hexdigest()])
    scope = f"{day}/{REGION}/kms/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    k = _sign(("AWS4" + CFG["secret_access_key"]).encode(), day)
    for part in (REGION, "kms", "aws4_request"):
        k = _sign(k, part)
    headers["authorization"] = (f"AWS4-HMAC-SHA256 Credential={CFG['access_key_id']}/{scope}, "
                                f"SignedHeaders={';'.join(names)}, "
                                f"Signature={hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()}")
    req = urllib.request.Request(f"https://{HOST}/", data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return base64.b64decode(json.load(r)["Plaintext"])


def key_for(edk):
    k = KEYS.get(edk)
    if k is None:
        k = KEYS[edk] = kms_decrypt(edk)
    return k


def dec(value, key):
    if not isinstance(value, str) or not value.startswith(PREFIX):
        return value
    blob = base64.b64decode(value[len(PREFIX):])
    d = Cipher(algorithms.AES(key), modes.CBC(blob[:16])).decryptor()
    u = padding.PKCS7(128).unpadder()
    return (u.update(d.update(blob[16:]) + d.finalize()) + u.finalize()).decode()


def as_text(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False)
    return "" if v is None else str(v)


for line in sys.stdin:
    row = json.loads(line)
    edk = row.get("edk") or ""
    if not edk:  # no key on the row: pass through, nothing to decrypt
        out = {"email": "", "phone": "", "properties": {}}
    else:
        key = key_for(edk)
        props = json.loads(row.get("properties") or "{}")
        out = {"email": dec(row.get("email_enc", ""), key), "phone": dec(row.get("phone_enc", ""), key),
               "properties": {n: as_text(dec(v, key)) for n, v in props.items()}}
    sys.stdout.write(json.dumps({"result": json.dumps(out, ensure_ascii=False)}, ensure_ascii=False) + "\n")
    sys.stdout.flush()
