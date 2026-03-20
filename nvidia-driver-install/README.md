# NVIDIA Driver Installer

Downloads the latest NVIDIA Gaming driver from a private S3 bucket and silently installs it on Windows.

## Prerequisites

- [AWS Tools for PowerShell](https://aws.amazon.com/powershell/) installed and configured
- IAM credentials with `s3:GetObject` and `s3:ListBucket` on the `nvidia-gaming` bucket
- Run PowerShell **as Administrator**

## Usage

**Run directly (one-liner):**
```powershell
irm https://raw.githubusercontent.com/phantom-computer/scripts-and-utilities/main/nvidia-driver-install/Install-NvidiaDriver.ps1 | iex
```

**Or download and run manually:**
```powershell
.\Install-NvidiaDriver.ps1
```

## What it does

1. Downloads all files under `s3://nvidia-gaming/windows/latest/` to `%USERPROFILE%\Desktop\NVIDIA`
2. Locates the `.exe` installer in the downloaded files
3. Runs a **silent install** with `-s -noreboot -noeula -clean Display.Driver` (core display driver only, no GeForce Experience)
4. Reports success or prompts for reboot as needed

## Notes

- A reboot is recommended after installation even if not strictly required.
- To include GeForce Experience, remove `Display.Driver` from `$InstallArgs` and replace with an empty string or desired components.
