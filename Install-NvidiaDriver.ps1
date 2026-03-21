# Install-NvidiaDriver.ps1
# Downloads the latest NVIDIA Gaming driver from S3, silently installs it,
# registers the GridSwCert license, and verifies the install.

$Bucket    = "nvidia-gaming"
$KeyPrefix = "windows/latest"
$LocalPath = "$home\Desktop\NVIDIA"

# Ensure destination directory exists
if (-not (Test-Path $LocalPath)) {
    New-Item -ItemType Directory -Path $LocalPath | Out-Null
}

# ── Step 1: Download driver files from S3 ────────────────────────────────────
Write-Host "Downloading NVIDIA driver files from s3://$Bucket/$KeyPrefix ..."
$Objects = Get-S3Object -BucketName $Bucket -KeyPrefix $KeyPrefix -Region us-east-1

foreach ($Object in $Objects) {
    $LocalFileName = $Object.Key
    if ($LocalFileName -ne '' -and $Object.Size -ne 0) {
        $LocalFilePath = Join-Path $LocalPath $LocalFileName
        # Create subdirectory structure if needed
        $Dir = Split-Path $LocalFilePath -Parent
        if (-not (Test-Path $Dir)) {
            New-Item -ItemType Directory -Path $Dir | Out-Null
        }
        Write-Host "  Downloading: $($Object.Key)"
        Copy-S3Object -BucketName $Bucket -Key $Object.Key -LocalFile $LocalFilePath -Region us-east-1
    }
}

# ── Step 2: Run the silent installer ─────────────────────────────────────────
$Installer = Get-ChildItem -Path $LocalPath -Recurse -Filter "*.exe" | Select-Object -First 1

if (-not $Installer) {
    Write-Error "No installer (.exe) found in $LocalPath. Aborting."
    exit 1
}

Write-Host "Launching installer: $($Installer.FullName)"

# Silent install: core display driver only, no GeForce Experience
$InstallArgs = "-s -noreboot -noeula -clean Display.Driver"

$Process = Start-Process -FilePath $Installer.FullName `
                         -ArgumentList $InstallArgs `
                         -Wait `
                         -PassThru

if ($Process.ExitCode -eq 0) {
    Write-Host "NVIDIA driver installed successfully."
} elseif ($Process.ExitCode -eq 1) {
    Write-Host "Installer returned exit code 1 — reboot will be required."
} else {
    Write-Error "Installer exited with code $($Process.ExitCode). Check NVIDIA logs for details."
    exit $Process.ExitCode
}

# ── Step 3: Register the GridSwCert license ──────────────────────────────────
Write-Host "Downloading NVIDIA Gaming license certificate..."

# Determine driver version to select the correct cert
$NvidiaSmi = Get-ChildItem -Path "C:\" -Recurse -Filter "nvidia-smi.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
$CertUrl = $null

if ($NvidiaSmi) {
    $VersionOutput = & $NvidiaSmi.FullName --query-gpu=driver_version --format=csv,noheader 2>$null
    $DriverVersion = [version]($VersionOutput.Trim().Split(" ")[0])

    if ($DriverVersion -ge [version]"591.59") {
        $CertUrl = "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCert_2026_03_02.cert"
    } elseif ($DriverVersion -ge [version]"460.39") {
        $CertUrl = "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCertWindows_2024_02_22.cert"
    } elseif ($DriverVersion -ge [version]"445.87") {
        $CertUrl = "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCert-Windows_2020_04.cert"
    } else {
        $CertUrl = "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCert-Windows_2019_09.cert"
    }
} else {
    # Default to latest cert if driver version can't be determined yet
    Write-Host "  nvidia-smi not found yet — using latest cert (driver may need reboot first)."
    $CertUrl = "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCert_2026_03_02.cert"
}

$CertDest = "$Env:PUBLIC\Documents\GridSwCert.txt"

# Enable TLS 1.2 in case running on older Windows Server
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Invoke-WebRequest -Uri $CertUrl -OutFile $CertDest
Write-Host "  Certificate saved to: $CertDest"

# ── Step 4: Reboot ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Installation complete. Rebooting in 10 seconds to apply changes..."
Write-Host "Press Ctrl+C to cancel the reboot."
Start-Sleep -Seconds 10
Restart-Computer -Force
