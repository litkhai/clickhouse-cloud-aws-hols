// Decrypt API — stands in for an application-owned service. POST /decrypt
//   request : {"rows": [{"tenant": "t003", "props": "<jsonb text: {name: '<ver>:<base64>', …}>"}, …]}
//   response: {"rows": [{name: '<plaintext>' | '<ver>:<base64>' (kept encrypted), …}, …]}  same order, same count
// Values are '<key version>:' + base64(AES-256-CBC, PKCS#7) with a fixed IV per key version (no IV in the value).
// One data key per column and version, wrapped by one KMS master key; this function's role unwraps a key once per
// cold start (KMS Decrypt) and keeps it in memory. Which properties stay encrypted is decided here, per tenant.
import crypto from "node:crypto";
import { KMSClient, DecryptCommand } from "@aws-sdk/client-kms";
import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";

const kms = new KMSClient({});
const ssm = new SSMClient({});
const keys = new Map(); // "<column>:<version>" -> {key, iv}
let ring = null;
let ringAt = 0;
let kmsCalls = 0;

async function loadRing() {
  const r = await ssm.send(new GetParameterCommand({ Name: process.env.KEYRING_PARAM }));
  ring = JSON.parse(r.Parameter.Value);
  ringAt = Date.now();
}

async function keyFor(column, version) {
  const id = `${column}:${version}`;
  let k = keys.get(id);
  if (k) return k;
  let e = ring.keys[id];
  if (!e && Date.now() - ringAt > 5000) { await loadRing(); e = ring.keys[id]; } // a new version after rotation
  if (!e) throw new Error(`unknown key ${id}`);
  const r = await kms.send(new DecryptCommand({ CiphertextBlob: Buffer.from(e.edk, "base64") }));
  kmsCalls++;
  k = { key: Buffer.from(r.Plaintext), iv: Buffer.from(e.iv, "hex") };
  keys.set(id, k);
  return k;
}

const VALUE = /^(\d+):([A-Za-z0-9+/=]+)$/;

function decrypt(b64, k) {
  const d = crypto.createDecipheriv("aes-256-cbc", k.key, k.iv);
  return Buffer.concat([d.update(Buffer.from(b64, "base64")), d.final()]).toString("utf8");
}

export const handler = async (event) => {
  const auth = event.headers?.authorization || event.headers?.Authorization || "";
  if (auth !== `Bearer ${process.env.API_TOKEN}`) {
    return { statusCode: 401, body: JSON.stringify({ error: "unauthorized" }) };
  }
  const t0 = Date.now();
  if (!ring) await loadRing();
  const body = JSON.parse(event.isBase64Encoded ? Buffer.from(event.body, "base64").toString() : event.body);
  let values = 0, kept = 0;
  const out = [];
  for (const row of body.rows) {
    const keep = new Set(ring.keep[row.tenant] || []);
    const props = typeof row.props === "string" ? JSON.parse(row.props || "{}") : row.props || {};
    const res = {};
    for (const [name, v] of Object.entries(props)) {
      const m = typeof v === "string" ? VALUE.exec(v) : null;
      if (!m) { res[name] = v; continue; }            // not a ciphertext: pass through
      if (keep.has(name)) { res[name] = v; kept++; continue; } // stays encrypted in ClickHouse
      res[name] = decrypt(m[2], await keyFor("props", m[1]));
      values++;
    }
    out.push(res);
  }
  console.log(JSON.stringify({ rows: out.length, values, kept, ms: Date.now() - t0, kmsCalls }));
  return { statusCode: 200, headers: { "content-type": "application/json" }, body: JSON.stringify({ rows: out }) };
};
