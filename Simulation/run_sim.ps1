# Runs all three testbenches in ModelSim and copies the full-game log to Simulation\Reports\game_log.txt.
#   tb_sonar : game core unit test (random start/goal, map quality, sonar, torpedo, hit, win/lose)
#   tb_lcd   : LCD pin protocol at 500 Hz
#   tb_game  : full games through the top-level pins at the real 500 Hz clock
param(
 [string]$ModelSim = 'C:\intelFPGA\20.1\modelsim_ase\win32aloem\vsim.exe'
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $ModelSim)) { throw "ModelSim not found: $ModelSim" }
$projectDir = Split-Path -Parent $PSScriptRoot
$rtlDir = Join-Path $projectDir 'RTL'
$tbDir = Join-Path $projectDir 'tb'
$designs = @('sonar_support.v','sonar_game_core.v','text_lcd_driver.v','submarine_sonar_top.v')
$tests = @('tb_sonar.v','tb_lcd.v','tb_game.v')
foreach ($name in $designs) {
 if (!(Test-Path -LiteralPath (Join-Path $rtlDir $name))) { throw "Missing RTL: $name" }
}
foreach ($name in $tests) {
 if (!(Test-Path -LiteralPath (Join-Path $tbDir $name))) { throw "Missing testbench: $name" }
}
# ModelSim cannot handle the non-ASCII project path, so simulate in a temporary ASCII folder.
$simDir = Join-Path $env:TEMP ('sonar_sim_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simDir | Out-Null
foreach ($name in $designs) { Copy-Item -LiteralPath (Join-Path $rtlDir $name) -Destination $simDir }
foreach ($name in $tests) { Copy-Item -LiteralPath (Join-Path $tbDir $name) -Destination $simDir }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sim.do') -Destination $simDir
Write-Host "Simulation output: $simDir"
Push-Location -LiteralPath $simDir
try {
 & $ModelSim -c -do "do sim.do"
 $code = $LASTEXITCODE
} finally { Pop-Location }
$log = Join-Path $simDir 'game_log.txt'
if (Test-Path -LiteralPath $log) {
 Copy-Item -LiteralPath $log -Destination (Join-Path $PSScriptRoot 'Reports\game_log.txt') -Force
}
if ($code -ne 0) { throw "ModelSim failed. Inspect $simDir\transcript" }
Write-Host 'All simulations passed.'
