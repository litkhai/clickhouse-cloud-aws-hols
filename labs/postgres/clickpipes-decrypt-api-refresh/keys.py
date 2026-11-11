#!/usr/bin/env python3
"""Create one data key per column for a key version and publish it to the key ring.

  keys.py --version 1      # props:1, email:1, phone:1
  keys.py --version 2      # rotation: adds props:2, email:2, phone:2 (version 1 stays readable)

Each data key comes from KMS GenerateDataKey (AES_256) under the lab's master key, with a random fixed IV
(16 B) for that key version. The key ring in SSM gets only the KMS-encrypted blob and the IV:
  {"keys": {"props:1": {"edk": <base64>, "iv": <hex>}, …}, "keep": {"t000": ["name", "birthday"], …}}
"keep" lists, per tenant, the properties that stay encrypted in ClickHouse (the decrypt API reads it).

The plaintext keys are written to out/keys/v<version>.json (mode 600) only because the data generator runs
inside Postgres (pgcrypto) and needs them; destroy.sh removes out/.

Run with: uv run --with boto3 keys.py --version 1   (env: AWS credentials; KEYRING_PARAM, KMS_ALIAS)
"""
import argparse
import base64
import json
import os

import boto3

COLUMNS = ("props", "email", "phone")
TENANTS = [f"t{i:03d}" for i in range(8)]


def keep_for(tenant):  # same rule as lab_keep() in pg/01-schema.sql
    return ["name", "birthday"] if int(tenant[-1]) % 2 == 0 else ["name"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", type=int, required=True)
    a = ap.parse_args()
    param, alias = os.environ["KEYRING_PARAM"], os.environ["KMS_ALIAS"]
    kms, ssm = boto3.client("kms"), boto3.client("ssm")
    ring = json.loads(ssm.get_parameter(Name=param)["Parameter"]["Value"])
    plain = {}
    for col in COLUMNS:
        r = kms.generate_data_key(KeyId=alias, KeySpec="AES_256")
        iv = os.urandom(16)
        ring["keys"][f"{col}:{a.version}"] = {"edk": base64.b64encode(r["CiphertextBlob"]).decode(), "iv": iv.hex()}
        plain[col] = {"key": r["Plaintext"].hex(), "iv": iv.hex()}
    ring["keep"] = {t: keep_for(t) for t in TENANTS}
    ssm.put_parameter(Name=param, Value=json.dumps(ring), Type="String", Overwrite=True)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "keys")
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, f"v{a.version}.json")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(plain, f)
    print(f"version {a.version}: {len(COLUMNS)} GenerateDataKey calls, key ring now {sorted(ring['keys'])}")


if __name__ == "__main__":
    main()
