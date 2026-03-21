#!/usr/bin/env python3
"""
ec2_cost.py - Monthly cost breakdown for an EC2 instance.

Calculates:
  - Runtime hours per instance type (handles mid-month type changes via CloudTrail)
  - Egress bandwidth cost (CloudWatch NetworkOut)
  - EBS storage cost (per volume, per type)

Usage:
  python3 ec2_cost.py --instance-id i-0abc1234567890 [--month 2026-03] [--region us-east-1] [--os linux]

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


def get_cloudtrail_events(ct_client, instance_id, start, end):
    events = []
    kwargs = {
        "LookupAttributes": [{"AttributeKey": "ResourceName", "Value": instance_id}],
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


def get_instance_type_price(instance_type, region, os_type):
    """Query AWS Pricing API for on-demand hourly price. Returns None if not found."""
    location = REGION_LOCATION_MAP.get(region, "US East (N. Virginia)")
    os_name  = "Windows" if os_type.lower() == "windows" else "Linux"
    pricing  = boto3.client("pricing", region_name="us-east-1")
    try:
        resp = pricing.get_products(
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
    """
    Reconstruct running hours per instance type using CloudTrail.
    Looks back 90 days before month start to establish initial state/type.
    Returns: {"g4dn.xlarge": 312.5, ...}
    """
    ct = boto3.client("cloudtrail", region_name=region)
    lookback_start = start - timedelta(days=90)
    all_events = get_cloudtrail_events(ct, instance_id, lookback_start, end)

    relevant = {"StartInstances", "StopInstances", "TerminateInstances", "ModifyInstanceAttribute"}
    events = sorted(
        [e for e in all_events if e["EventName"] in relevant],
        key=lambda e: e["EventTime"]
    )

    # Normalize timestamps to UTC
    def to_utc(ts):
        if ts.tzinfo is None:
            return ts.replace(tzinfo=timezone.utc)
        return ts.astimezone(timezone.utc)

    # Build timeline: (timestamp, action, value)
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

    # Replay pre-month events to find state/type at month start
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

    # Walk in-month events and accumulate hours per type
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

    # Account for remaining time to end of period
    if cur_running:
        delta = (end - cur_ts).total_seconds() / 3600
        hours_by_type[cur_type] = hours_by_type.get(cur_type, 0.0) + delta

    return hours_by_type


def get_network_out_gb(instance_id, start, end, region):
    """Sum CloudWatch NetworkOut and return total GB."""
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
    """Return list of dicts for all EBS volumes attached to the instance."""
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

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="EC2 monthly cost breakdown")
    parser.add_argument("--instance-id", required=True, help="EC2 instance ID (i-xxxx)")
    parser.add_argument("--month",  default=datetime.now(timezone.utc).strftime("%Y-%m"),
                        help="Month to analyze, YYYY-MM (default: current month)")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--os",     default=None,
                        help="linux or windows (auto-detected from instance if omitted)")
    args = parser.parse_args()

    ec2_client   = boto3.client("ec2", region_name=args.region)
    start, end   = get_month_bounds(args.month)

    try:
        resp = ec2_client.describe_instances(InstanceIds=[args.instance_id])
        inst = resp["Reservations"][0]["Instances"][0]
    except (ClientError, IndexError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    current_type  = inst["InstanceType"]
    current_state = inst["State"]["Name"]
    os_type       = args.os or inst.get("Platform", "linux")

    print(f"\n{'='*64}")
    print(f"  EC2 Cost Report  |  {args.instance_id}")
    print(f"  Period : {start.strftime('%Y-%m-%d')} to {end.strftime('%Y-%m-%d %H:%M')} UTC")
    print(f"  State  : {current_state}  |  Type: {current_type}  |  OS: {os_type}")
    print(f"{'='*64}\n")

    # ── Runtime ──────────────────────────────────────────────────────────────
    print("RUNTIME")
    print(f"  {'Instance Type':<22} {'Hours':>8}  {'Rate':>14}  {'Cost':>10}")
    print(f"  {'-'*22} {'-'*8}  {'-'*14}  {'-'*10}")

    hours_by_type = build_runtime_by_type(
        args.instance_id, current_type, current_state, start, end, args.region
    )
    total_runtime_cost = 0.0
    for itype, hours in sorted(hours_by_type.items()):
        price = get_instance_type_price(itype, args.region, os_type)
        cost  = hours * price if price else 0.0
        total_runtime_cost += cost
        rate_str = f"${price:.4f}/hr" if price else "N/A"
        print(f"  {itype:<22} {hours:>8.2f}  {rate_str:>14}  ${cost:>9.2f}")
    print(f"  {'-'*22} {'-'*8}  {'-'*14}  {'-'*10}")
    print(f"  {'TOTAL':<22} {'':>8}  {'':>14}  ${total_runtime_cost:>9.2f}\n")

    # ── Egress ───────────────────────────────────────────────────────────────
    print("EGRESS (NetworkOut)")
    total_gb    = get_network_out_gb(args.instance_id, start, end, args.region)
    billable_gb = max(0.0, total_gb - EGRESS_FREE_GB)
    egress_cost = billable_gb * EGRESS_COST_PER_GB
    print(f"  Total transfer : {total_gb:>10.3f} GB")
    print(f"  Free tier      : {EGRESS_FREE_GB:>10.0f} GB")
    print(f"  Billable       : {billable_gb:>10.3f} GB  @  ${EGRESS_COST_PER_GB}/GB")
    print(f"  {'Cost':<36}  ${egress_cost:>9.2f}\n")

    # ── EBS ──────────────────────────────────────────────────────────────────
    print("EBS STORAGE")
    print(f"  {'Volume ID':<24} {'Type':<8} {'Size':>8}  {'Rate':>13}  {'Cost':>10}")
    print(f"  {'-'*24} {'-'*8} {'-'*8}  {'-'*13}  {'-'*10}")
    volumes        = get_ebs_volumes(args.instance_id, args.region)
    total_ebs_cost = 0.0
    for v in volumes:
        rate_str = f"${v['price_per_gb']:.3f}/GB-mo"
        print(f"  {v['volume_id']:<24} {v['type']:<8} {v['size_gb']:>6} GB  {rate_str:>13}  ${v['monthly_cost']:>9.2f}")
        total_ebs_cost += v["monthly_cost"]
    print(f"  {'-'*24} {'-'*8} {'-'*8}  {'-'*13}  {'-'*10}")
    print(f"  {'TOTAL':<56}  ${total_ebs_cost:>9.2f}\n")

    # ── Summary ──────────────────────────────────────────────────────────────
    grand_total = total_runtime_cost + egress_cost + total_ebs_cost
    print(f"{'='*64}")
    print(f"  Runtime  : ${total_runtime_cost:>9.2f}")
    print(f"  Egress   : ${egress_cost:>9.2f}")
    print(f"  EBS      : ${total_ebs_cost:>9.2f}")
    print(f"  {'-'*38}")
    print(f"  TOTAL    : ${grand_total:>9.2f}")
    print(f"{'='*64}\n")


if __name__ == "__main__":
    main()
