#!/usr/bin/env python3
"""
ec2_cost.py - Monthly cost breakdown for EC2 instance(s).

Can target a single instance or all instances matching a tag filter.

Usage:
  # Single instance
  python3 ec2_cost.py --instance-id i-0abc1234567890

  # All instances owned by a user (UUID in Owner tag)
  python3 ec2_cost.py --tag-value 94682438-4091-706e-4193-1b79bdc3d3da

  # Custom tag key
  python3 ec2_cost.py --tag-key user_id --tag-value <uuid>

  # With options
  python3 ec2_cost.py --tag-value <uuid> --month 2026-03 --region us-east-1

Required IAM permissions:
  cloudtrail:LookupEvents, cloudwatch:GetMetricStatistics,
  ec2:DescribeInstances, ec2:DescribeVolumes, pricing:GetProducts
"""

import argparse
import json
import sys
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

# ── Pricing constants ─────────────────────────────────────────────────────────

EGRESS_COST_PER_GB = 0.09
EGRESS_FREE_GB     = 100

EBS_PRICE_MAP = {
    "gp2":      0.10,
    "gp3":      0.08,
    "io1":      0.125,
    "io2":      0.125,
    "st1":      0.045,
    "sc1":      0.025,
    "standard": 0.05,
}

REGION_LOCATION_MAP = {
    "us-east-1":      "US East (N. Virginia)",
    "us-east-2":      "US East (Ohio)",
    "us-west-1":      "US West (N. California)",
    "us-west-2":      "US West (Oregon)",
    "eu-west-1":      "Europe (Ireland)",
    "eu-west-2":      "Europe (London)",
    "eu-central-1":   "Europe (Frankfurt)",
    "ap-southeast-1": "Asia Pacific (Singapore)",
    "ap-southeast-2": "Asia Pacific (Sydney)",
    "ap-northeast-1": "Asia Pacific (Tokyo)",
    "ca-central-1":   "Canada (Central)",
}

# ── Helpers ───────────────────────────────────────────────────────────────────

def get_month_bounds(month_str):
    start = datetime.strptime(month_str, "%Y-%m").replace(tzinfo=timezone.utc)
    if start.month == 12:
        end = start.replace(year=start.year + 1, month=1)
    else:
        end = start.replace(month=start.month + 1)
    return start, min(end, datetime.now(timezone.utc))


def find_instances_by_tag(ec2_client, tag_key, tag_value):
    """Return list of instance dicts matching the given tag key/value."""
    resp = ec2_client.describe_instances(
        Filters=[{"Name": f"tag:{tag_key}", "Values": [tag_value]}]
    )
    instances = []
    for res in resp["Reservations"]:
        for inst in res["Instances"]:
            instances.append(inst)
    return instances


def get_instance(ec2_client, instance_id):
    resp = ec2_client.describe_instances(InstanceIds=[instance_id])
    return resp["Reservations"][0]["Instances"][0]


def get_tag(instance, key, default=""):
    for t in (instance.get("Tags") or []):
        if t["Key"] == key:
            return t["Value"]
    return default


def get_cloudtrail_events(ct_client, instance_id, start, end):
    events = []
    kwargs = {
        "LookupAttributes": [{"AttributeKey": "ResourceName", "AttributeValue": instance_id}],
        "StartTime": start,
        "EndTime": end,
        "MaxResults": 50,
    }
    while True:
        resp = ct_client.lookup_events(**kwargs)
        events.extend(resp["Events"])
        if "NextToken" not in resp:
            break
        kwargs["NextToken"] = resp["NextToken"]
    return events


def get_instance_type_price(pricing_client, instance_type, region, os_type):
    location = REGION_LOCATION_MAP.get(region, "US East (N. Virginia)")
    os_name  = "Windows" if os_type.lower() == "windows" else "Linux"
    try:
        resp = pricing_client.get_products(
            ServiceCode="AmazonEC2",
            Filters=[
                {"Type": "TERM_MATCH", "Field": "instanceType",    "Value": instance_type},
                {"Type": "TERM_MATCH", "Field": "location",        "Value": location},
                {"Type": "TERM_MATCH", "Field": "operatingSystem", "Value": os_name},
                {"Type": "TERM_MATCH", "Field": "tenancy",         "Value": "Shared"},
                {"Type": "TERM_MATCH", "Field": "capacitystatus",  "Value": "Used"},
                {"Type": "TERM_MATCH", "Field": "preInstalledSw",  "Value": "NA"},
            ],
            MaxResults=5,
        )
    except ClientError as e:
        print(f"  [warn] Pricing API error: {e}", file=sys.stderr)
        return None

    for item_str in resp["PriceList"]:
        item = json.loads(item_str)
        for term in item.get("terms", {}).get("OnDemand", {}).values():
            for pd in term.get("priceDimensions", {}).values():
                price = float(pd["pricePerUnit"].get("USD", 0))
                if price > 0:
                    return price
    return None

# ── Core calculations ─────────────────────────────────────────────────────────

def build_runtime_by_type(instance_id, current_type, current_state, start, end, region):
    ct = boto3.client("cloudtrail", region_name=region)
    lookback_start = start - timedelta(days=90)
    all_events = get_cloudtrail_events(ct, instance_id, lookback_start, end)

    relevant = {"StartInstances", "StopInstances", "TerminateInstances", "ModifyInstanceAttribute"}
    events = sorted(
        [e for e in all_events if e["EventName"] in relevant],
        key=lambda e: e["EventTime"]
    )

    def to_utc(ts):
        if ts.tzinfo is None:
            return ts.replace(tzinfo=timezone.utc)
        return ts.astimezone(timezone.utc)

    timeline = []
    for e in events:
        name   = e["EventName"]
        ts     = to_utc(e["EventTime"])
        detail = json.loads(e["CloudTrailEvent"])

        if name == "StartInstances":
            timeline.append((ts, "start", None))
        elif name in ("StopInstances", "TerminateInstances"):
            timeline.append((ts, "stop", None))
        elif name == "ModifyInstanceAttribute":
            itype_val = (detail.get("requestParameters") or {}).get("instanceType", {})
            new_type  = itype_val.get("value") if isinstance(itype_val, dict) else None
            if new_type:
                timeline.append((ts, "type_change", new_type))

    cur_type    = current_type
    cur_running = current_state == "running"

    for ts, action, val in timeline:
        if ts >= start:
            break
        if action == "start":
            cur_running = True
        elif action == "stop":
            cur_running = False
        elif action == "type_change":
            cur_type = val

    hours_by_type = {}
    cur_ts = start

    for ts, action, val in timeline:
        if ts < start:
            continue
        if ts >= end:
            break
        if cur_running:
            delta = (ts - cur_ts).total_seconds() / 3600
            hours_by_type[cur_type] = hours_by_type.get(cur_type, 0.0) + delta
        cur_ts = ts
        if action == "start":
            cur_running = True
        elif action == "stop":
            cur_running = False
        elif action == "type_change":
            cur_type = val

    if cur_running:
        delta = (end - cur_ts).total_seconds() / 3600
        hours_by_type[cur_type] = hours_by_type.get(cur_type, 0.0) + delta

    return hours_by_type


def get_network_out_gb(instance_id, start, end, region):
    cw   = boto3.client("cloudwatch", region_name=region)
    resp = cw.get_metric_statistics(
        Namespace="AWS/EC2",
        MetricName="NetworkOut",
        Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
        StartTime=start,
        EndTime=end,
        Period=86400,
        Statistics=["Sum"],
        Unit="Bytes",
    )
    total_bytes = sum(dp["Sum"] for dp in resp["Datapoints"])
    return total_bytes / (1024 ** 3)


def get_ebs_volumes(instance_id, region):
    ec2  = boto3.client("ec2", region_name=region)
    resp = ec2.describe_volumes(
        Filters=[{"Name": "attachment.instance-id", "Values": [instance_id]}]
    )
    results = []
    for vol in resp["Volumes"]:
        vtype = vol["VolumeType"]
        size  = vol["Size"]
        price = EBS_PRICE_MAP.get(vtype, 0.08)
        results.append({
            "volume_id":    vol["VolumeId"],
            "type":         vtype,
            "size_gb":      size,
            "price_per_gb": price,
            "monthly_cost": size * price,
        })
    return results

# ── Per-instance report ───────────────────────────────────────────────────────

def report_instance(inst, start, end, region, os_override, pricing_client):
    instance_id   = inst["InstanceId"]
    current_type  = inst["InstanceType"]
    current_state = inst["State"]["Name"]
    os_type       = os_override or inst.get("Platform", "linux")
    name          = get_tag(inst, "Name", instance_id)
    owner         = get_tag(inst, "Owner", "—")
    inst_uuid     = get_tag(inst, "InstanceUUID", "—")

    print(f"\n{'='*68}")
    print(f"  {name}  ({instance_id})")
    print(f"  Owner : {owner}")
    if inst_uuid != "—":
        print(f"  UUID  : {inst_uuid}")
    print(f"  State : {current_state}  |  Type: {current_type}  |  OS: {os_type}")
    print(f"  Period: {start.strftime('%Y-%m-%d')} → {end.strftime('%Y-%m-%d %H:%M')} UTC")
    print(f"{'='*68}\n")

    # Runtime
    print("RUNTIME")
    print(f"  {'Instance Type':<22} {'Hours':>8}  {'Rate':>14}  {'Cost':>10}")
    print(f"  {'-'*22} {'-'*8}  {'-'*14}  {'-'*10}")
    hours_by_type = build_runtime_by_type(
        instance_id, current_type, current_state, start, end, region
    )
    total_runtime_cost = 0.0
    for itype, hours in sorted(hours_by_type.items()):
        price = get_instance_type_price(pricing_client, itype, region, os_type)
        cost  = hours * price if price else 0.0
        total_runtime_cost += cost
        rate_str = f"${price:.4f}/hr" if price else "N/A"
        print(f"  {itype:<22} {hours:>8.2f}  {rate_str:>14}  ${cost:>9.2f}")
    print(f"  {'-'*22} {'-'*8}  {'-'*14}  {'-'*10}")
    print(f"  {'TOTAL':<22} {'':>8}  {'':>14}  ${total_runtime_cost:>9.2f}\n")

    # Egress
    print("EGRESS (NetworkOut)")
    total_gb    = get_network_out_gb(instance_id, start, end, region)
    billable_gb = max(0.0, total_gb - EGRESS_FREE_GB)
    egress_cost = billable_gb * EGRESS_COST_PER_GB
    print(f"  Total transfer : {total_gb:>10.3f} GB")
    print(f"  Free tier      : {EGRESS_FREE_GB:>10.0f} GB")
    print(f"  Billable       : {billable_gb:>10.3f} GB  @  ${EGRESS_COST_PER_GB}/GB")
    print(f"  {'Cost':<36}  ${egress_cost:>9.2f}\n")

    # EBS
    print("EBS STORAGE")
    print(f"  {'Volume ID':<24} {'Type':<8} {'Size':>8}  {'Rate':>13}  {'Cost':>10}")
    print(f"  {'-'*24} {'-'*8} {'-'*8}  {'-'*13}  {'-'*10}")
    volumes        = get_ebs_volumes(instance_id, region)
    total_ebs_cost = 0.0
    for v in volumes:
        rate_str = f"${v['price_per_gb']:.3f}/GB-mo"
        print(f"  {v['volume_id']:<24} {v['type']:<8} {v['size_gb']:>6} GB  {rate_str:>13}  ${v['monthly_cost']:>9.2f}")
        total_ebs_cost += v["monthly_cost"]
    print(f"  {'-'*24} {'-'*8} {'-'*8}  {'-'*13}  {'-'*10}")
    print(f"  {'TOTAL':<56}  ${total_ebs_cost:>9.2f}\n")

    grand_total = total_runtime_cost + egress_cost + total_ebs_cost
    print(f"  Runtime  : ${total_runtime_cost:>9.2f}")
    print(f"  Egress   : ${egress_cost:>9.2f}")
    print(f"  EBS      : ${total_ebs_cost:>9.2f}")
    print(f"  {'-'*38}")
    print(f"  TOTAL    : ${grand_total:>9.2f}")

    return grand_total

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="EC2 monthly cost breakdown")

    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--instance-id",  help="Single EC2 instance ID (i-xxxx)")
    target.add_argument("--tag-value",    help="Filter all instances by tag value (UUID)")

    parser.add_argument("--tag-key",  default="Owner",
                        help="Tag key to filter on when using --tag-value (default: Owner)")
    parser.add_argument("--month",    default=datetime.now(timezone.utc).strftime("%Y-%m"),
                        help="Month to analyze, YYYY-MM (default: current month)")
    parser.add_argument("--region",   default="us-east-1")
    parser.add_argument("--os",       default=None,
                        help="linux or windows (auto-detected from instance if omitted)")
    args = parser.parse_args()

    ec2_client     = boto3.client("ec2",     region_name=args.region)
    pricing_client = boto3.client("pricing", region_name="us-east-1")
    start, end     = get_month_bounds(args.month)

    if args.instance_id:
        try:
            inst = get_instance(ec2_client, args.instance_id)
        except (ClientError, IndexError) as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
        instances = [inst]
    else:
        instances = find_instances_by_tag(ec2_client, args.tag_key, args.tag_value)
        if not instances:
            print(f"No instances found with tag {args.tag_key}={args.tag_value}", file=sys.stderr)
            sys.exit(1)
        print(f"Found {len(instances)} instance(s) with {args.tag_key}={args.tag_value}")

    grand_totals = []
    for inst in instances:
        total = report_instance(inst, start, end, args.region, args.os, pricing_client)
        grand_totals.append(total)

    if len(instances) > 1:
        print(f"\n{'#'*68}")
        print(f"  ACCOUNT TOTAL for {args.tag_key}={args.tag_value}")
        print(f"  {len(instances)} instance(s)  |  {args.month}")
        print(f"  TOTAL : ${sum(grand_totals):>9.2f}")
        print(f"{'#'*68}\n")


if __name__ == "__main__":
    main()
