# EC2 Cost Tracker

Estimate the monthly cost of one or more EC2 instances using live AWS data — no Cost Explorer required. Available in Python and Bash.

## What it calculates

| Category | Source | Notes |
|---|---|---|
| **Runtime** | CloudTrail + Pricing API | Per-instance-type hours; handles mid-month type changes |
| **Egress** | CloudWatch `NetworkOut` | First 100 GB/mo free; $0.09/GB after |
| **EBS storage** | EC2 API | Per-volume, per-type pricing |

## Prerequisites

**Python version:**
```bash
pip install boto3
```

**Bash version:**
```bash
# Requires: aws CLI, jq, bc, python3 (for timeline + pricing math)
```

**IAM permissions required (both versions):**
```
cloudtrail:LookupEvents
cloudwatch:GetMetricStatistics
ec2:DescribeInstances
ec2:DescribeVolumes
pricing:GetProducts
```

## Usage

### Python (`ec2_cost.py`)

```bash
# Single instance
python3 ec2_cost.py --instance-id i-0abc1234567890

# All instances by Owner tag (UUID)
python3 ec2_cost.py --tag-value 94682438-4091-706e-4193-1b79bdc3d3da

# Custom tag key
python3 ec2_cost.py --tag-key user_id --tag-value <uuid>

# Specific month + region + OS override
python3 ec2_cost.py --tag-value <uuid> --month 2026-02 --region us-west-2 --os windows
```

### Bash (`ec2_cost.sh`)

```bash
chmod +x ec2_cost.sh

# Single instance
./ec2_cost.sh --instance-id i-0abc1234567890

# All instances by Owner tag (UUID)
./ec2_cost.sh --tag-value 94682438-4091-706e-4193-1b79bdc3d3da

# Custom tag key
./ec2_cost.sh --tag-key user_id --tag-value <uuid>

# Specific month + region + OS override
./ec2_cost.sh --tag-value <uuid> --month 2026-02 --region us-west-2 --os windows
```

## Tag filtering

Both scripts default `--tag-key` to `Owner`, which is the UUID-based user tag on instances in this account. Override with `--tag-key` to match any tag:

```bash
# By Owner (default)
./ec2_cost.sh --tag-value 94682438-4091-706e-4193-1b79bdc3d3da

# By InstanceUUID
./ec2_cost.sh --tag-key InstanceUUID --tag-value 2b12bd67-8386-44ba-baa6-8e990dc11fe9
```

When `--tag-value` matches multiple instances, each gets its own breakdown and a combined total is printed at the end.

## Example output

```
Found 2 instance(s) with Owner=94682438-4091-706e-4193-1b79bdc3d3da

====================================================================
  HOCH1  (i-0f1b698d1c60a1f02)
  Owner : 94682438-4091-706e-4193-1b79bdc3d3da
  UUID  : 2b12bd67-8386-44ba-baa6-8e990dc11fe9
  State : running    | Type: g7e.2xlarge       | OS: linux
  Period: 2026-03-01 → 2026-03-20T19:00:00Z
====================================================================

RUNTIME
  Instance Type          Hours            Rate        Cost
  ---------------------- --------  --------------  ----------
  g7e.2xlarge              456.00    $2.2950/hr     $ 1046.52
  ---------------------- --------  --------------  ----------
  TOTAL                                             $ 1046.52

EGRESS (NetworkOut)
  Total transfer :     243.817 GB
  Free tier      :     100     GB
  Billable       :     143.817 GB  @  $0.09/GB
  Cost                                              $   12.94

EBS STORAGE
  Volume ID                Type     Size           Rate        Cost
  ------------------------ -------- --------  -------------  ----------
  vol-0abc123              gp3       200 GB  $0.080/GB-mo   $   16.00
  ------------------------ -------- --------  -------------  ----------
  TOTAL                                                      $   16.00

  Runtime  :    $ 1046.52
  Egress   :    $   12.94
  EBS      :    $   16.00
  --------------------------------------
  TOTAL    :    $ 1075.46

####################################################################
  ACCOUNT TOTAL for Owner=94682438-4091-706e-4193-1b79bdc3d3da
  2 instance(s)  |  2026-03
  TOTAL :  $ 1823.91
####################################################################
```

## Notes

- CloudTrail lookback is 90 days — instance history beyond that won't be captured
- Pricing API queries `us-east-1` (AWS requirement) but uses the correct region's prices
- EBS pricing uses standard on-demand rates; IOPS charges for `io1`/`io2` are not included
- Bash version requires `python3` for CloudTrail timeline reconstruction and Pricing API JSON parsing
