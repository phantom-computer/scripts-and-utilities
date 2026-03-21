# Install-NvidiaDriver.ps1
# Downloads the latest NVIDIA Gaming driver from S3 and silently installs it.
#
# Set $Bucket and $KeyPrefix to match your S3 layout before running.

$Bucket    = "<your-s3-bucket>"
$KeyPrefix = "windows/latest"
$LocalPath = "$home\Desktop\NVIDIA"

# Ensure destination directory exists
if (-not (Test-Path $LocalPath)) {
    New-Item -ItemType Directory -Path $LocalPath | Out-Null
}

# Download all objects under the key prefix
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

# Find the installer (.exe) in the downloaded files
$Installer = Get-ChildItem -Path $LocalPath -Recurse -Filter "*.exe" | Select-Object -First 1

if (-not $Installer) {
    Write-Error "No installer (.exe) found in $LocalPath. Aborting."
    exit 1
}

Write-Host "Launching installer: $($Installer.FullName)"

# Silent install: extract only the core display driver components, no GeForce Experience
$InstallArgs = "-s -noreboot -noeula -clean Display.Driver"

$Process = Start-Process -FilePath $Installer.FullName `
                         -ArgumentList $InstallArgs `
                         -Wait `
                         -PassThru

if ($Process.ExitCode -eq 0) {
    Write-Host "NVIDIA driver installed successfully. A reboot is recommended."
} elseif ($Process.ExitCode -eq 1) {
    Write-Host "Installer returned exit code 1 — reboot required to complete installation."
} else {
    Write-Error "Installer exited with code $($Process.ExitCode). Check NVIDIA logs for details."
    exit $Process.ExitCode
}
