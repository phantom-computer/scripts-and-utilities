#!/usr/bin/env bash
# ec2_cost.sh - Monthly EC2 cost breakdown (runtime + egress + EBS)
#
# Requires: aws CLI, jq, bc
#
# Usage:
#   # Single instance
#   ./ec2_cost.sh --instance-id i-0abc1234567890
#
#   # All instances owned by a user (UUID in Owner tag)
#   ./ec2_cost.sh --tag-value 94682438-4091-706e-4193-1b79bdc3d3da
#
#   # Custom tag key
#   ./ec2_cost.sh --tag-key user_id --tag-value <uuid>
#
#   # With options
#   ./ec2_cost.sh --tag-value <uuid> --month 2026-03 --region us-east-1

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REGION="us-east-1"
MONTH=$(date -u +"%Y-%m")
OS_OVERRIDE=""
INSTANCE_ID=""
TAG_KEY="Owner"
TAG_VALUE=""

# ── EBS pricing (per GB-month) ────────────────────────────────────────────────
ebs_price() {
  case "$1" in
    gp2)      echo "0.10"  ;;
    gp3)      echo "0.08"  ;;
    io1|io2)  echo "0.125" ;;
    st1)      echo "0.045" ;;
    sc1)      echo "0.025" ;;
    standard) echo "0.05"  ;;
    *)        echo "0.08"  ;;
  esac
}

EGRESS_RATE="0.09"
EGRESS_FREE="100"

# ── Arg parsing ───────────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --tag-key)     TAG_KEY="$2";     shift 2 ;;
    --tag-value)   TAG_VALUE="$2";   shift 2 ;;
    --month)       MONTH="$2";       shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    --os)          OS_OVERRIDE="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

if [[ -z "$INSTANCE_ID" && -z "$TAG_VALUE" ]]; then
  echo "Error: must provide --instance-id or --tag-value"
  usage
fi
if [[ -n "$INSTANCE_ID" && -n "$TAG_VALUE" ]]; then
  echo "Error: --instance-id and --tag-value are mutually exclusive"
  usage
fi

# ── Date math ─────────────────────────────────────────────────────────────────
month_bounds() {
  local month="$1"
  local year=${month%-*}
  local mon=${month#*-}
  local start="${year}-${mon}-01T00:00:00Z"
  local next_year=$year
  local next_mon=$((10#$mon + 1))
  if [[ $next_mon -gt 12 ]]; then next_mon=1; next_year=$((year + 1)); fi
  local end
  end=$(printf "%04d-%02d-01T00:00:00Z" "$next_year" "$next_mon")
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [[ "$end" > "$now" ]]; then end="$now"; fi
  echo "$start $end"
}

read -r PERIOD_START PERIOD_END <<< "$(month_bounds "$MONTH")"

# ── AWS pricing API ───────────────────────────────────────────────────────────
REGION_LOCATION_MAP() {
  case "$1" in
    us-east-1)      echo "US East (N. Virginia)"       ;;
    us-east-2)      echo "US East (Ohio)"              ;;
    us-west-1)      echo "US West (N. California)"     ;;
    us-west-2)      echo "US West (Oregon)"            ;;
    eu-west-1)      echo "Europe (Ireland)"            ;;
    eu-west-2)      echo "Europe (London)"             ;;
    eu-central-1)   echo "Europe (Frankfurt)"          ;;
    ap-southeast-1) echo "Asia Pacific (Singapore)"    ;;
    ap-southeast-2) echo "Asia Pacific (Sydney)"       ;;
    ap-northeast-1) echo "Asia Pacific (Tokyo)"        ;;
    ca-central-1)   echo "Canada (Central)"            ;;
    *)              echo "US East (N. Virginia)"       ;;
  esac
}

get_instance_price() {
  local itype="$1" os_type="$2"
  local location
  location=$(REGION_LOCATION_MAP "$REGION")
  local os_name="Linux"
  [[ "${os_type,,}" == "windows" ]] && os_name="Windows"

  local price
  price=$(aws pricing get-products \
    --region us-east-1 \
    --service-code AmazonEC2 \
    --filters \
      "Type=TERM_MATCH,Field=instanceType,Value=${itype}" \
      "Type=TERM_MATCH,Field=location,Value=${location}" \
      "Type=TERM_MATCH,Field=operatingSystem,Value=${os_name}" \
      "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
      "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
      "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
    --max-results 5 \
    --query 'PriceList[0]' \
    --output text 2>/dev/null \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for term in data.get('terms',{}).get('OnDemand',{}).values():
    for pd in term.get('priceDimensions',{}).values():
        p = float(pd['pricePerUnit'].get('USD',0))
        if p > 0:
            print(p)
            sys.exit(0)
" 2>/dev/null || echo "0")
  echo "$price"
}

# ── CloudTrail: build runtime hours per instance type ─────────────────────────
build_runtime() {
  local instance_id="$1" cur_type="$2" cur_state="$3"

  # Lookback 90 days before month start
  local lookback
  lookback=$(date -u -d "${PERIOD_START} - 90 days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v-90d -jf "%Y-%m-%dT%H:%M:%SZ" "${PERIOD_START}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || echo "${PERIOD_START}")

  # Collect all relevant CloudTrail events (paginated)
  local all_events="[]"
  local next_token=""
  while true; do
    local resp
    local extra_args=()
    [[ -n "$next_token" ]] && extra_args=(--next-token "$next_token")
    resp=$(aws cloudtrail lookup-events \
      --region "$REGION" \
      --lookup-attributes AttributeKey=ResourceName,AttributeValue="$instance_id" \
      --start-time "$lookback" \
      --end-time "$PERIOD_END" \
      --max-results 50 \
      "${extra_args[@]}" \
      --output json 2>/dev/null || echo '{"Events":[],"NextToken":""}')

    local page_events
    page_events=$(echo "$resp" | jq '.Events // []')
    all_events=$(echo "$all_events $page_events" | jq -s 'add')

    next_token=$(echo "$resp" | jq -r '.NextToken // ""')
    [[ -z "$next_token" ]] && break
  done

  # Parse events, reconstruct timeline via embedded Python
  python3 - "$instance_id" "$cur_type" "$cur_state" "$PERIOD_START" "$PERIOD_END" \
    <<'PYEOF_INNER'
import json, sys
from datetime import datetime, timezone

instance_id, cur_type, cur_state = sys.argv[1], sys.argv[2], sys.argv[3]
start = datetime.fromisoformat(sys.argv[4].replace("Z","+00:00"))
end   = datetime.fromisoformat(sys.argv[5].replace("Z","+00:00"))

raw = sys.stdin.read().strip()
events_raw = json.loads(raw) if raw else []

relevant = {"RunInstances","StartInstances","StopInstances","TerminateInstances","ModifyInstanceAttribute"}

def to_utc(ts_str):
    dt = datetime.fromisoformat(ts_str) if isinstance(ts_str, str) else ts_str
    if dt.tzinfo is None: dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)

# Find creation time and original instance type from RunInstances event
creation_time = None
initial_type  = None
for e in sorted(events_raw, key=lambda x: x["EventTime"]):
    if e.get("EventName") == "RunInstances":
        creation_time = to_utc(e["EventTime"])
        detail        = json.loads(e.get("CloudTrailEvent","{}"))
        initial_type  = (detail.get("requestParameters") or {}).get("instanceType")
        break

timeline = []
for e in events_raw:
    name = e.get("EventName","")
    if name not in relevant: continue
    ts     = to_utc(e["EventTime"])
    detail = json.loads(e.get("CloudTrailEvent","{}"))
    if name in ("RunInstances","StartInstances"):
        timeline.append((ts, "start", None))
    elif name in ("StopInstances","TerminateInstances"):
        timeline.append((ts, "stop", None))
    elif name == "ModifyInstanceAttribute":
        iv = (detail.get("requestParameters") or {}).get("instanceType",{})
        nt = iv.get("value") if isinstance(iv, dict) else None
        if nt: timeline.append((ts, "type_change", nt))

timeline.sort(key=lambda x: x[0])

ct = cur_type

if creation_time and creation_time > start:
    # Instance created this month — billing starts at creation, not month start.
    # Use type from RunInstances so pre-upgrade sessions are priced correctly.
    effective_start = creation_time
    cur_running     = False
    if initial_type:
        ct = initial_type
else:
    # Instance existed before this month — replay pre-month events.
    # Fall back to current_state only for instances older than 90-day lookback.
    effective_start = start
    cur_running     = (cur_state == "running")
    for ts, action, val in timeline:
        if ts >= start: break
        if action == "start":        cur_running = True
        elif action == "stop":       cur_running = False
        elif action == "type_change": ct = val

hours_by_type = {}
warnings      = []
cur_ts = effective_start
for ts, action, val in timeline:
    if ts < effective_start: continue
    if ts >= end:            break
    if action == "start":
        if cur_running:
            # AWS rejects StartInstances on a running instance — a second start
            # means a stop event is missing from CloudTrail. Don't count the gap.
            warnings.append(
                f"  [warn] Missing stop before {ts.strftime('%Y-%m-%d %H:%M UTC')}; "
                f"gap {cur_ts.strftime('%H:%M')}→{ts.strftime('%H:%M')} not counted"
            )
            cur_ts = ts
        else:
            cur_ts      = ts
            cur_running = True
    elif action == "stop":
        if cur_running:
            delta = (ts - cur_ts).total_seconds() / 3600
            hours_by_type[ct] = hours_by_type.get(ct, 0.0) + delta
        cur_running = False
    elif action == "type_change":
        if cur_running:
            delta = (ts - cur_ts).total_seconds() / 3600
            hours_by_type[ct] = hours_by_type.get(ct, 0.0) + delta
            cur_ts = ts
        ct = val

import sys
if cur_running:
    if cur_state == "running":
        # Instance is still running — count up to end of period.
        delta = (end - cur_ts).total_seconds() / 3600
        hours_by_type[ct] = hours_by_type.get(ct, 0.0) + delta
    else:
        # Instance is stopped but no StopInstances event in CloudTrail.
        # Happens when OS initiates shutdown (e.g. Windows shut down from within).
        # We know it stopped but not when — don't count the trailing segment.
        warnings.append(
            f"  [warn] No StopInstances after {cur_ts.strftime('%Y-%m-%d %H:%M UTC')}; "
            f"instance is stopped but stop time unknown — trailing segment not counted"
        )

for w in warnings: print(w, file=sys.stderr)

for itype, hours in sorted(hours_by_type.items()):
    print(f"{itype} {hours:.4f}")
PYEOF_INNER
}

# ── Egress ────────────────────────────────────────────────────────────────────
get_egress_gb() {
  local instance_id="$1"
  aws cloudwatch get-metric-statistics \
    --region "$REGION" \
    --namespace "AWS/EC2" \
    --metric-name "NetworkOut" \
    --dimensions Name=InstanceId,Value="$instance_id" \
    --start-time "$PERIOD_START" \
    --end-time   "$PERIOD_END" \
    --period 86400 \
    --statistics Sum \
    --unit Bytes \
    --query 'sum(Datapoints[*].Sum)' \
    --output text 2>/dev/null \
  | awk '{printf "%.6f\n", $1 / (1024^3)}'
}

# ── EBS volumes ───────────────────────────────────────────────────────────────
get_ebs_cost() {
  local instance_id="$1"
  aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=attachment.instance-id,Values=${instance_id}" \
    --query 'Volumes[*].{id:VolumeId,type:VolumeType,size:Size}' \
    --output json 2>/dev/null \
  | python3 - << 'PYEOF'
import json, sys
vols = json.load(sys.stdin)
EBS = {"gp2":0.10,"gp3":0.08,"io1":0.125,"io2":0.125,"st1":0.045,"sc1":0.025,"standard":0.05}
total = 0
for v in vols:
    price = EBS.get(v["type"], 0.08)
    cost  = v["size"] * price
    total += cost
    print(f"{v['id']} {v['type']} {v['size']} {price:.3f} {cost:.2f}")
print(f"TOTAL {total:.2f}")
PYEOF
}

# ── Pretty print helpers ──────────────────────────────────────────────────────
sep()  { printf '%0.s=' {1..68}; echo; }
dash() { printf '%0.s-' {1..68}; echo; }
bc_calc() { echo "scale=4; $1" | bc -l 2>/dev/null || python3 -c "print(round($1, 4))"; }

# ── Per-instance report ───────────────────────────────────────────────────────
report_instance() {
  local instance_id="$1"

  # Describe instance
  local inst_json
  inst_json=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0]' \
    --output json 2>/dev/null)

  local cur_type cur_state platform name owner inst_uuid
  cur_type=$(echo "$inst_json" | jq -r '.InstanceType')
  cur_state=$(echo "$inst_json" | jq -r '.State.Name')
  platform=$(echo "$inst_json" | jq -r '.Platform // "linux"')
  name=$(echo "$inst_json" | jq -r '(.Tags // []) | map(select(.Key=="Name")) | .[0].Value // "'$instance_id'"')
  owner=$(echo "$inst_json" | jq -r '(.Tags // []) | map(select(.Key=="Owner")) | .[0].Value // "—"')
  inst_uuid=$(echo "$inst_json" | jq -r '(.Tags // []) | map(select(.Key=="InstanceUUID")) | .[0].Value // "—"')

  local os_type="${OS_OVERRIDE:-$platform}"

  sep
  printf "  %-30s (%s)\n" "$name" "$instance_id"
  printf "  Owner : %s\n" "$owner"
  [[ "$inst_uuid" != "—" ]] && printf "  UUID  : %s\n" "$inst_uuid"
  printf "  State : %-10s | Type: %-16s | OS: %s\n" "$cur_state" "$cur_type" "$os_type"
  printf "  Period: %s → %s\n" "${PERIOD_START%T*}" "${PERIOD_END}"
  sep; echo

  # ── Runtime ────────────────────────────────────────────────────────────────
  echo "RUNTIME"
  printf "  %-22s %8s  %14s  %10s\n" "Instance Type" "Hours" "Rate" "Cost"
  printf "  %-22s %8s  %14s  %10s\n" "$(printf '%0.s-' {1..22})" "--------" "--------------" "----------"

  local total_runtime_cost=0
  local runtime_lines
  runtime_lines=$(build_runtime "$instance_id" "$cur_type" "$cur_state" <<< "")

  while IFS=' ' read -r itype hours; do
    [[ -z "$itype" ]] && continue
    local price
    price=$(get_instance_price "$itype" "$os_type")
    local cost=0
    if [[ "$price" != "0" && -n "$price" ]]; then
      cost=$(bc_calc "$hours * $price")
      local rate_str
      rate_str=$(printf '$%.4f/hr' "$price")
    else
      rate_str="N/A"
    fi
    printf "  %-22s %8.2f  %14s  \$%9.2f\n" "$itype" "$hours" "$rate_str" "$cost"
    total_runtime_cost=$(bc_calc "$total_runtime_cost + $cost")
  done <<< "$runtime_lines"

  printf "  %-22s %8s  %14s  %10s\n" "$(printf '%0.s-' {1..22})" "--------" "--------------" "----------"
  printf "  %-22s %8s  %14s  \$%9.2f\n\n" "TOTAL" "" "" "$total_runtime_cost"

  # ── Egress ──────────────────────────────────────────────────────────────────
  echo "EGRESS (NetworkOut)"
  local total_gb
  total_gb=$(get_egress_gb "$instance_id")
  local billable_gb
  billable_gb=$(bc_calc "if ($total_gb - $EGRESS_FREE) > 0 then ($total_gb - $EGRESS_FREE) else 0 end" \
    || python3 -c "print(max(0, $total_gb - $EGRESS_FREE))")
  local egress_cost
  egress_cost=$(bc_calc "$billable_gb * $EGRESS_RATE")
  printf "  Total transfer : %10.3f GB\n" "$total_gb"
  printf "  Free tier      : %10.0f GB\n" "$EGRESS_FREE"
  printf "  Billable       : %10.3f GB  @  \$%s/GB\n" "$billable_gb" "$EGRESS_RATE"
  printf "  %-36s  \$%9.2f\n\n" "Cost" "$egress_cost"

  # ── EBS ─────────────────────────────────────────────────────────────────────
  echo "EBS STORAGE"
  printf "  %-24s %-8s %8s  %13s  %10s\n" "Volume ID" "Type" "Size" "Rate" "Cost"
  printf "  %-24s %-8s %8s  %13s  %10s\n" \
    "$(printf '%0.s-' {1..24})" "--------" "--------" "-------------" "----------"

  local total_ebs_cost=0
  local ebs_lines
  ebs_lines=$(get_ebs_cost "$instance_id")
  local ebs_total_line=""

  while IFS=' ' read -r vid vtype vsize vprice vcost; do
    [[ "$vid" == "TOTAL" ]] && { ebs_total_line="$vcost"; continue; }
    printf "  %-24s %-8s %6s GB  \$%s/GB-mo  \$%9.2f\n" "$vid" "$vtype" "$vsize" "$vprice" "$vcost"
  done <<< "$ebs_lines"
  total_ebs_cost="${ebs_total_line:-0}"

  printf "  %-24s %-8s %8s  %13s  %10s\n" \
    "$(printf '%0.s-' {1..24})" "--------" "--------" "-------------" "----------"
  printf "  %-57s  \$%9.2f\n\n" "TOTAL" "$total_ebs_cost"

  # ── Summary ──────────────────────────────────────────────────────────────────
  local grand_total
  grand_total=$(bc_calc "$total_runtime_cost + $egress_cost + $total_ebs_cost")
  printf "  Runtime  : \$%9.2f\n" "$total_runtime_cost"
  printf "  Egress   : \$%9.2f\n" "$egress_cost"
  printf "  EBS      : \$%9.2f\n" "$total_ebs_cost"
  printf "  %s\n" "$(printf '%0.s-' {1..38})"
  printf "  TOTAL    : \$%9.2f\n" "$grand_total"

  echo "$grand_total"
}

# ── Discover instances ────────────────────────────────────────────────────────
if [[ -n "$INSTANCE_ID" ]]; then
  INSTANCE_IDS=("$INSTANCE_ID")
else
  mapfile -t INSTANCE_IDS < <(
    aws ec2 describe-instances \
      --region "$REGION" \
      --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
      --query 'Reservations[*].Instances[*].InstanceId' \
      --output text 2>/dev/null | tr '\t' '\n'
  )
  if [[ ${#INSTANCE_IDS[@]} -eq 0 ]]; then
    echo "No instances found with tag ${TAG_KEY}=${TAG_VALUE}" >&2
    exit 1
  fi
  echo "Found ${#INSTANCE_IDS[@]} instance(s) with ${TAG_KEY}=${TAG_VALUE}"
fi

# ── Run reports ───────────────────────────────────────────────────────────────
total_all=0
for iid in "${INSTANCE_IDS[@]}"; do
  inst_total=$(report_instance "$iid")
  total_all=$(bc_calc "$total_all + $inst_total")
done

if [[ ${#INSTANCE_IDS[@]} -gt 1 ]]; then
  echo
  printf '%0.s#' {1..68}; echo
  printf "  ACCOUNT TOTAL for %s=%s\n" "$TAG_KEY" "$TAG_VALUE"
  printf "  %d instance(s)  |  %s\n" "${#INSTANCE_IDS[@]}" "$MONTH"
  printf "  TOTAL : \$%9.2f\n" "$total_all"
  printf '%0.s#' {1..68}; echo
  echo
fi
