#!/usr/bin/env python3
"""Cost of the run: EMR from the AWS Price List x the cluster's instances and step times, and
ClickHouse Cloud from the Usage Cost API.

Usage: ./05-cost.py <utc-date-of-run YYYY-MM-DD>
Needs AWS credentials (pricing:GetProducts, elasticmapreduce:Describe*/List*) and .env.
Prints JSON. Prices are on-demand list prices on the day of the call; the result is an estimate,
not a bill (no billing console is used).
"""
import base64
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
vals = dict(os.environ)
for line in (HERE / ".env").read_text().splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.split("=", 1)
        vals.setdefault(k.strip(), v.strip())
REGION = vals.get("AWS_REGION", "ap-northeast-2")


def aws(*args, region=REGION):
    out = subprocess.run(["aws", *args, "--region", region, "--output", "json"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def price(service, instance_type):
    filters = [f"Type=TERM_MATCH,Field=regionCode,Value={REGION}",
               f"Type=TERM_MATCH,Field=instanceType,Value={instance_type}"]
    if service == "AmazonEC2":
        filters += ["Type=TERM_MATCH,Field=operatingSystem,Value=Linux",
                    "Type=TERM_MATCH,Field=tenancy,Value=Shared",
                    "Type=TERM_MATCH,Field=preInstalledSw,Value=NA",
                    "Type=TERM_MATCH,Field=capacitystatus,Value=Used"]
    else:
        filters += ["Type=TERM_MATCH,Field=softwareType,Value=EMR"]
    res = aws("pricing", "get-products", "--service-code", service, "--filters", *filters, region="us-east-1")
    usd = set()
    for item in res["PriceList"]:
        p = json.loads(item)
        for term in p["terms"]["OnDemand"].values():
            for dim in term["priceDimensions"].values():
                usd.add(float(dim["pricePerUnit"]["USD"]))
    usd.discard(0.0)
    assert len(usd) == 1, (service, instance_type, usd)
    return usd.pop()


def ebs_price(volume_type):
    """USD per GB-month for an EBS volume type in REGION."""
    res = aws("pricing", "get-products", "--service-code", "AmazonEC2", "--filters",
              f"Type=TERM_MATCH,Field=regionCode,Value={REGION}",
              "Type=TERM_MATCH,Field=productFamily,Value=Storage",
              f"Type=TERM_MATCH,Field=volumeApiName,Value={volume_type}", region="us-east-1")
    usd = {float(d["pricePerUnit"]["USD"]) for item in res["PriceList"]
           for t in json.loads(item)["terms"]["OnDemand"].values() for d in t["priceDimensions"].values()}
    assert len(usd) == 1, (volume_type, usd)
    return usd.pop()


def ts(s):
    return datetime.fromisoformat(s)


def emr():
    cid = (HERE / ".cluster-id").read_text().strip()
    c = aws("emr", "describe-cluster", "--cluster-id", cid)["Cluster"]
    hourly, nodes, gb = 0.0, [], {}
    for g in c["InstanceGroups"]:
        ec2, uplift = price("AmazonEC2", g["InstanceType"]), price("ElasticMapReduce", g["InstanceType"])
        n = g["RequestedInstanceCount"]
        hourly += n * (ec2 + uplift)
        nodes.append({"group": g["InstanceGroupType"], "type": g["InstanceType"], "count": n,
                      "ec2_per_hour": ec2, "emr_per_hour": uplift})
        for d in g.get("EbsBlockDevices", []):
            v = d["VolumeSpecification"]
            gb[v["VolumeType"]] = gb.get(v["VolumeType"], 0) + n * v["SizeInGB"]
        # Root volume: describe-cluster leaves EbsRootVolumeSize empty when the default is used;
        # describe-volumes on the 2026-11-25 run showed one 15 GiB gp3 root volume per node.
        gb["gp3"] = gb.get("gp3", 0) + n * (c.get("EbsRootVolumeSize") or 15)
    ebs_hourly = sum(size * ebs_price(t) / 730 for t, size in gb.items())
    hourly += ebs_hourly
    tl = c["Status"]["Timeline"]
    created = ts(tl["CreationDateTime"])
    end = ts(tl["EndDateTime"]) if "EndDateTime" in tl else datetime.now(created.tzinfo)
    steps = []
    for s in aws("emr", "list-steps", "--cluster-id", cid)["Steps"]:
        stl = s["Status"]["Timeline"]
        if "StartDateTime" in stl and "EndDateTime" in stl:
            sec = (ts(stl["EndDateTime"]) - ts(stl["StartDateTime"])).total_seconds()
            steps.append({"step": s["Name"], "state": s["Status"]["State"], "seconds": sec,
                          "usd_at_cluster_rate": round(sec / 3600 * hourly, 4)})
    life = (end - created).total_seconds()
    ready = (ts(tl["ReadyDateTime"]) - created).total_seconds() if "ReadyDateTime" in tl else None
    return {"cluster": cid, "release": c["ReleaseLabel"], "nodes": nodes, "ebs_gb": gb,
            "ebs_usd_per_hour": round(ebs_hourly, 4), "usd_per_hour": round(hourly, 4),
            "seconds_to_ready": ready, "lifetime_seconds": life,
            "lifetime_usd": round(life / 3600 * hourly, 4), "steps": sorted(steps, key=lambda x: x["step"])}


def clickhouse(day):
    auth = base64.b64encode(f"{vals['CHC_KEY']}:{vals['CHC_SECRET']}".encode()).decode()
    url = (f"https://api.clickhouse.cloud/v1/organizations/{vals['CHC_ORG_ID']}/usageCost"
           f"?from_date={day}&to_date={day}")
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}"})
    res = json.load(urllib.request.urlopen(req))["result"]
    rows = [r for r in res["costs"] if r.get("serviceId") == vals["CHC_SERVICE_ID"]
            or r.get("entityId") == vals["CHC_SERVICE_ID"]]
    return {"date": day, "service_records": [{k: r[k] for k in ("entityType", "locked", "metrics", "totalCHC")}
                                             for r in rows]}


if __name__ == "__main__":
    print(json.dumps({"emr": emr(), "clickhouse_usage_cost": clickhouse(sys.argv[1])}, indent=2, default=str))
