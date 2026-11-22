param(
 [string]$ModelSim = 'C:\intelFPGA\20.1\modelsim_ase\win32aloem\vsim.exe',
 [ValidateSet('Fast','Timing','All')][string]$Mode = 'Fast'
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $ModelSim)) { throw "ModelSim not found: $ModelSim" }
$projectDir = Split-Path -Parent $PSScriptRoot
$rtlDir = Join-Path $projectDir 'RTL'
$tbDir = Join-Path $projectDir 'tb'
$designs = @('sonar_support.v','sonar_game_core.v','text_lcd_driver.v','submarine_sonar_top.v')
$tests = @('tb_sonar.v','tb_top.v','tb_lcd.v')
# Validate paths before creating the temporary simulation directory.
foreach ($name in $designs) {
 if (!(Test-Path -LiteralPath (Join-Path $rtlDir $name))) { throw "Missing RTL: $name" }
}
foreach ($name in $tests) {
 if (!(Test-Path -LiteralPath (Join-Path $tbDir $name))) { throw "Missing testbench: $name" }
}
$simDir = Join-Path $env:TEMP ('sonar_sim_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simDir | Out-Null
foreach ($name in $designs) { Copy-Item -LiteralPath (Join-Path $rtlDir $name) -Destination $simDir }
foreach ($name in $tests) { Copy-Item -LiteralPath (Join-Path $tbDir $name) -Destination $simDir }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sim.do') -Destination $simDir
Write-Host "Mode: $Mode; simulation output: $simDir"
Push-Location -LiteralPath $simDir
try {
 & $ModelSim -c -do "set mode $Mode; do sim.do"
 if ($LASTEXITCODE -ne 0) { throw "ModelSim failed. Inspect $simDir\transcript" }
} finally { Pop-Location }
