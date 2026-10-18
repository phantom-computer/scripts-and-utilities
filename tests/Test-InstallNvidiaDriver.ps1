# pwsh -NoProfile -File tests/Test-InstallNvidiaDriver.ps1   (no Pester, no AWS, no downloads)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../Install-NvidiaDriver.ps1"
$script:fail = 0; $script:pass = 0
function Check($name, $cond) { if ($cond) { $script:pass++; "PASS - $name" } else { $script:fail++; "FAIL - $name" } }
function CertFor($v) { (Get-GridSwCertUrl ([version]$v) 3>$null).Split('/')[-1] }

Check '616.92 -> 2026'             ((CertFor '616.92') -eq 'GridSwCert_2026_03_02.cert')
Check '591.59 -> 2026 (boundary)'  ((CertFor '591.59') -eq 'GridSwCert_2026_03_02.cert')
Check '581.80 -> 2025 (was 2024)'  ((CertFor '581.80') -eq 'GridSwCertWindows_2025_07_01.cert')
Check '580.88 -> 2025 (was 2024)'  ((CertFor '580.88') -eq 'GridSwCertWindows_2025_07_01.cert')
Check '576.80 -> 2025 (boundary)'  ((CertFor '576.80') -eq 'GridSwCertWindows_2025_07_01.cert')
Check '576.72 -> 2024 (boundary)'  ((CertFor '576.72') -eq 'GridSwCertWindows_2024_02_22.cert')
Check '576.52 -> 2024'             ((CertFor '576.52') -eq 'GridSwCertWindows_2024_02_22.cert')
Check '460.39 -> 2024 (boundary)'  ((CertFor '460.39') -eq 'GridSwCertWindows_2024_02_22.cert')
Check '445.87 -> 2020_04'          ((CertFor '445.87') -eq 'GridSwCert-Windows_2020_04.cert')
Check '441.12 -> 2019_09'          ((CertFor '441.12') -eq 'GridSwCert-Windows_2019_09.cert')
Check 'gap 585.00 -> 2025 + warning' (((CertFor '585.00') -eq 'GridSwCertWindows_2025_07_01.cert') -and ((Get-GridSwCertUrl ([version]'585.00') 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) -ne $null))
Check 'gap 576.75 -> 2024'         ((CertFor '576.75') -eq 'GridSwCertWindows_2024_02_22.cert')
Check 'filename parse'             ((Get-DriverVersionFromInstaller '616.92_Cloud_Gaming_win10_win11_server2022_dch_64bit_international.exe') -eq [version]'616.92')
Check 'filename unparsable -> null' ($null -eq (Get-DriverVersionFromInstaller 'setup.exe'))
# Every Windows build in s3://nvidia-gaming/windows/ (listed 2026-10-18) maps without a gap warning.
$listed = '441.12 441.66 441.87 516.94 517.48 522.25 527.27 528.24 528.49 531.41 531.68 531.79 536.25 536.67 537.13 537.42 546.01 546.29 546.65 551.61 551.71 552.13 555.99 556.12 560.81 566.03 566.14 572.16 572.60 572.83 576.52 576.80 580.88 581.22 581.42 581.57 581.80 591.59 591.74 595.59 595.71 595.97 596.36 610.47 610.88 616.92'.Split(' ')
$warned = $listed | Where-Object { Get-GridSwCertUrl ([version]$_) 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } }
Check 'no published build falls in a gap' ($warned.Count -eq 0)
"`n$script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
