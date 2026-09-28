# Build a single Bluejay target on Windows with the Keil 8051 toolchain that
# ships with Silicon Labs Simplicity Studio (free license for EFM8 parts).
#
# Example (Mobula8 2023 ESC, Z_H_30):
#   powershell -ExecutionPolicy Bypass -File tools\build-windows.ps1 -Layout Z -Mcu H -Deadtime 30 -Pwm 48
#
# Output: build\hex\Z_H_30_48_<Version>.hex

param(
    [string]$Layout = "Z",
    [ValidateSet("H", "X")][string]$Mcu = "H",
    [int]$Deadtime = 30,
    [ValidateSet(24, 48, 96)][int]$Pwm = 48,
    [string]$Version = "3dfix",
    [string]$KeilPath = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Locate Keil
if (-not $KeilPath) {
    $candidates = @(
        "C:\SiliconLabs\SimplicityStudio\v5\developer\toolchains\keil_8051\9.60\BIN",
        "C:\SiliconLabs\SimplicityStudio\v4\developer\toolchains\keil_8051\9.60\BIN",
        "C:\Keil_v5\C51\BIN"
    )
    $KeilPath = $candidates | Where-Object { Test-Path (Join-Path $_ "AX51.exe") } | Select-Object -First 1
}
if (-not $KeilPath -or -not (Test-Path (Join-Path $KeilPath "AX51.exe"))) {
    Write-Error "Could not find AX51.exe. Install Simplicity Studio (Keil 8051 toolchain) or pass -KeilPath <...\BIN>"
}

$AX51 = Join-Path $KeilPath "AX51.exe"
$LX51 = Join-Path $KeilPath "LX51.exe"
$OX51 = Join-Path $KeilPath "Ohx51.exe"

# Same defines the Makefile computes
if ($Layout -eq "OA") { $escNo = 27 } else { $escNo = [int][char]$Layout.ToUpper()[0] - 64 }
$mcuType = @{ "H" = 1; "X" = 2 }[$Mcu]
$pwmFreq = @{ 24 = 0; 48 = 1; 96 = 2 }[$Pwm]

$name = "${Layout}_${Mcu}_${Deadtime}_${Pwm}_${Version}"
New-Item -ItemType Directory -Force -Path "build\hex" | Out-Null
$obj = "build\$name.OBJ"; $lst = "build\$name.LST"; $omf = "build\$name.OMF"
$map = "build\$($name.ToUpper()).MAP"; $hex = "build\hex\$name.hex"

Write-Host "AX51 : $obj"
& $AX51 "src\Bluejay.asm" "INCDIR(.\src\Settings) " "DEFINE(ESCNO=$escNo) " "DEFINE(MCU_TYPE=$mcuType) " `
    "DEFINE(DEADTIME=$Deadtime) " "DEFINE(PWM_FREQ=$pwmFreq) " "OBJECT($obj) " "PRINT($lst) " `
    "NOMOD51 REGISTERBANK(0,1,2) NOLIST NOSYMBOLS" | Out-Null
if ($LASTEXITCODE -ge 2 -or (Select-String -Path $lst -Pattern "\*\*\* (ERROR|WARNING)" -Quiet)) {
    Select-String -Path $lst -Pattern "\*\*\* (ERROR|WARNING)" -Context 3, 0
    Write-Error "Assembly failed - see $lst"
}

Write-Host "LX51 : $omf"
& $LX51 $obj TO $omf | Out-Null
$mapFile = Get-ChildItem build -Filter "*.MAP" | Where-Object { $_.Name -ieq "$name.MAP" } | Select-Object -First 1
if ($LASTEXITCODE -ge 2 -or -not $mapFile -or -not (Select-String -Path $mapFile.FullName -Pattern "1 WARNING" -Quiet)) {
    # A clean Bluejay link produces exactly 1 warning (bootloader overlap)
    if ($mapFile) { Select-String -Path $mapFile.FullName -Pattern "\*\*\* (ERROR|WARNING)" -Context 0, 3 }
    Write-Error "Link failed - see build\*.MAP"
}

Write-Host "OHX  : $hex"
& $OX51 $omf "HEXFILE ($hex)" | Out-Null
if (-not (Test-Path $hex)) { Write-Error "Could not make hex file" }

Write-Host "`nDone: $hex"
