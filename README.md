# NVIDIA Driver Installer

Downloads the latest NVIDIA Gaming driver from a private S3 bucket, silently installs it, registers the GridSwCert license, and reboots.

## Prerequisites

- [AWS Tools for PowerShell](https://aws.amazon.com/powershell/) installed and configured with default credentials
- IAM credentials with `s3:GetObject` and `s3:ListBucket` on the `nvidia-gaming` bucket
- Run PowerShell **as Administrator**
- If using a custom Windows AMI, it must be Sysprep'd

## Setup


## Usage

**Run directly (one-liner):**
```powershell
irm https://raw.githubusercontent.com/phantom-computer/scripts-and-utilities/main/Install-NvidiaDriver.ps1 | iex
```

**Or download and run manually:**
```powershell
.\Install-NvidiaDriver.ps1
```

## What it does

1. Downloads all files under `s3://nvidia-gaming/windows/latest/` to `%USERPROFILE%\Desktop\NVIDIA`
2. Runs a **silent install** with `-s -noreboot -noeula -clean Display.Driver` (core display driver only, no GeForce Experience)
3. Downloads the correct **GridSwCert** license file based on the installed driver version and saves it to `%PUBLIC%\Documents\GridSwCert.txt`
4. Reboots the instance to complete installation

## Verifying the license (after reboot)

```powershell
$NvidiaSmi = Get-ChildItem -Path "C:\" -Recurse -Filter "nvidia-smi.exe" | Select-Object -First 1
& $NvidiaSmi.FullName -q
```

Look for:
```
vGPU Software Licensed Product
    Product Name : NVIDIA Cloud Gaming
    License Status : Licensed (Expiry: N/A)
```

## Notes

- To download all available driver versions instead of just the latest, change `$KeyPrefix` from `"windows/latest"` to `"windows"`.
- To include GeForce Experience, remove `Display.Driver` from `$InstallArgs`.
- Optional: set up [Amazon DCV](https://docs.aws.amazon.com/dcv/) for up to 4K single display support.
