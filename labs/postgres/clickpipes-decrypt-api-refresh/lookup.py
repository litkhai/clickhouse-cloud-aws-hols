#!/usr/bin/env python3
"""Print clickhouse-client parameters for sql/50-lookup.sql: the ciphertext of an email and of a name under every
key version in the key ring, the way the application builds a lookup (same key, fixed IV).

  lookup.py --user 5 --name 김민준   ->  line 1: emails ['1:…','2:…'], line 2: names (Array(String) literals)

Unwraps the data keys with KMS Decrypt (operator credentials). Run with: uv run --with boto3 --with cryptography lookup.py
"""
import argparse, base64, json, os
import boto3
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

ap = argparse.ArgumentParser()
ap.add_argument("--user", type=int, required=True)
ap.add_argument("--name", default="김민준")
a = ap.parse_args()
ring = json.loads(boto3.client("ssm").get_parameter(Name=os.environ["KEYRING_PARAM"])["Parameter"]["Value"])
kms = boto3.client("kms")


def enc(col, ver, text):
    e = ring["keys"][f"{col}:{ver}"]
    key = kms.decrypt(CiphertextBlob=base64.b64decode(e["edk"]))["Plaintext"]
    p = padding.PKCS7(128).padder()
    c = Cipher(algorithms.AES(key), modes.CBC(bytes.fromhex(e["iv"]))).encryptor()
    return f"{ver}:" + base64.b64encode(c.update(p.update(text.encode()) + p.finalize()) + c.finalize()).decode()


vers = sorted({int(k.split(":")[1]) for k in ring["keys"]})
q = lambda xs: "[" + ",".join("'" + x + "'" for x in xs) + "]"
print(q([enc("email", v, f"user{a.user}@example.com") for v in vers]))  # line 1: --param_emails
print(q([enc("props", v, a.name) for v in vers]))                      # line 2: --param_names
