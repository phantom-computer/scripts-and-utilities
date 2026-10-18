# Install-NvidiaDriver.ps1
# Downloads the latest NVIDIA Gaming driver from S3, silently installs it,
# registers the GridSwCert license, and verifies the install.

# ── Licence cert by driver version ───────────────────────────────────────────
# Windows ranges from AWS "Install NVIDIA gaming drivers" (checked 2026-10-18):
#   591.59 or later  -> GridSwCert_2026_03_02.cert
#   576.80 – 581.80  -> GridSwCertWindows_2025_07_01.cert
#   460.39 – 576.72  -> GridSwCertWindows_2024_02_22.cert
#   445.87           -> GridSwCert-Windows_2020_04.cert
#   earlier          -> GridSwCert-Windows_2019_09.cert
# AWS publishes no Windows gaming build in the gaps (576.73–576.79, 581.81–591.58); a build
# there takes the cert of the nearest lower range, with a warning.
$script:GridSwCertBase   = "https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive"
$script:GridSwCertLatest = "$script:GridSwCertBase/GridSwCert_2026_03_02.cert"

function Get-GridSwCertUrl([version]$Version) {
    if ($Version -ge [version]"591.59") { return $script:GridSwCertLatest }
    if ($Version -gt [version]"581.80") {
        Write-Warning "Driver $Version is between documented cert ranges; using the 2025-07-01 cert."
        return "$script:GridSwCertBase/GridSwCertWindows_2025_07_01.cert"
    }
    if ($Version -ge [version]"576.80") { return "$script:GridSwCertBase/GridSwCertWindows_2025_07_01.cert" }
    if ($Version -gt [version]"576.72") {
        Write-Warning "Driver $Version is between documented cert ranges; using the 2024-02-22 cert."
        return "$script:GridSwCertBase/GridSwCertWindows_2024_02_22.cert"
    }
    if ($Version -ge [version]"460.39") { return "$script:GridSwCertBase/GridSwCertWindows_2024_02_22.cert" }
    if ($Version -ge [version]"445.87") { return "$script:GridSwCertBase/GridSwCert-Windows_2020_04.cert" }
    return "$script:GridSwCertBase/GridSwCert-Windows_2019_09.cert"
}

function Get-DriverVersionFromInstaller([string]$FileName) {
    if ($FileName -match '^(\d+\.\d+)_') { return [version]$Matches[1] }
    return $null
}

# Dot-sourcing (". .\Install-NvidiaDriver.ps1") only loads the functions above (used by tests).
if ($MyInvocation.InvocationName -eq '.') { return }

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

# Determine driver version to select the correct cert.
# Prefer the version in the installer filename (e.g. 616.92_Cloud_Gaming_...exe): it is
# the driver we just installed, needs no reboot, and avoids picking a stale nvidia-smi.exe
# from an older DriverStore folder. Fall back to nvidia-smi only if the name doesn't parse.
$DriverVersion = Get-DriverVersionFromInstaller $Installer.Name
if (-not $DriverVersion) {
    $NvidiaSmi = Get-ChildItem -Path "$Env:SystemRoot\System32\DriverStore\FileRepository" -Recurse -Filter "nvidia-smi.exe" -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($NvidiaSmi) {
        $VersionOutput = & $NvidiaSmi.FullName --query-gpu=driver_version --format=csv,noheader 2>$null
        $DriverVersion = [version]($VersionOutput.Trim().Split(" ")[0])
    }
}

if ($DriverVersion) {
    Write-Host "  Driver version: $DriverVersion"
    $CertUrl = Get-GridSwCertUrl $DriverVersion
} else {
    # Default to latest cert if driver version can't be determined yet
    Write-Host "  Driver version unknown — using latest cert (driver may need reboot first)."
    $CertUrl = $script:GridSwCertLatest
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
