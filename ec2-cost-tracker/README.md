# EC2 Cost Tracker

A Python script that estimates the monthly cost of an EC2 instance using live AWS data — no Cost Explorer required.

## What it calculates

| Category | Source | Notes |
|---|---|---|
| **Runtime** | CloudTrail + Pricing API | Tracks per-instance-type hours; handles mid-month type changes |
| **Egress** | CloudWatch `NetworkOut` | First 100 GB/mo free; $0.09/GB after |
| **EBS storage** | EC2 API | Per-volume, per-type pricing |

## Prerequisites

```bash
pip install boto3
```

AWS credentials configured with:
- `cloudtrail:LookupEvents`
- `cloudwatch:GetMetricStatistics`
- `ec2:DescribeInstances`, `ec2:DescribeVolumes`
- `pricing:GetProducts`

## Usage

```bash
# Current month
python3 ec2_cost.py --instance-id i-0abc1234567890

# Specific month
python3 ec2_cost.py --instance-id i-0abc1234567890 --month 2026-02

# Different region / force OS type
python3 ec2_cost.py --instance-id i-0abc1234567890 --region us-west-2 --os windows
```

## Example output

```
================================================================
  EC2 Cost Report  |  i-0abc1234567890
  Period : 2026-03-01 to 2026-03-20 14:30 UTC
  State  : running  |  Type: g4dn.xlarge  |  OS: windows
================================================================

RUNTIME
  Instance Type          Hours            Rate        Cost
  ---------------------- --------  --------------  ----------
  g4dn.xlarge              312.50    $0.7260/hr     $  226.88
  g4dn.2xlarge              48.00    $1.1270/hr     $   54.10
  ---------------------- --------  --------------  ----------
  TOTAL                                             $  280.98

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

================================================================
  Runtime  :    $  280.98
  Egress   :    $   12.94
  EBS      :    $   16.00
  --------------------------------------
  TOTAL    :    $  309.92
================================================================
```

## Notes

- CloudTrail lookback is 90 days — instance history beyond that won't be captured
- Pricing API always queries `us-east-1` (AWS requirement) but uses the correct region's prices
- EBS pricing uses standard on-demand rates; IOPS charges for `io1`/`io2` are not included
