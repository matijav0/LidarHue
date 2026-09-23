<#
.SYNOPSIS
  Priprema Conda env "lidar_color" (PDAL + GDAL + Python) i verificira alate.

.DESCRIPTION
  Trazi Miniforge/Miniconda instalaciju, kreira env ako ne postoji,
  te ispise putanju koju treba upisati u config.json -> envRoot.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\backend\scripts\setup_env.ps1
  powershell -ExecutionPolicy Bypass -File .\backend\scripts\setup_env.ps1 -Force
#>
[CmdletBinding()]
param(
  [string]$EnvName = "lidar_color",
  [string]$CondaRoot = "",
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Find-CondaRoot {
  $candidates = @(
    "$env:USERPROFILE\miniforge3",
    "$env:USERPROFILE\miniconda3",
    "$env:USERPROFILE\anaconda3",
    "$env:USERPROFILE\mambaforge",
    "C:\ProgramData\miniforge3",
    "C:\ProgramData\miniconda3",
    "D:\miniforge3"
  )
  foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c "Scripts\conda.exe")) { return $c }
  }
  return $null
}

if ([string]::IsNullOrWhiteSpace($CondaRoot)) { $CondaRoot = Find-CondaRoot }

if (-not $CondaRoot) {
  Write-Host "Conda/Miniforge nije pronaden." -ForegroundColor Red
  Write-Host ""
  Write-Host "Instaliraj Miniforge pa ponovi:"
  Write-Host '  Invoke-WebRequest "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Windows-x86_64.exe" -OutFile "$env:TEMP\mf.exe"'
  Write-Host '  Start-Process "$env:TEMP\mf.exe" -ArgumentList "/InstallationType=JustMe","/RegisterPython=0","/S","/D=$env:USERPROFILE\miniforge3" -Wait'
  exit 1
}

Write-Host "Conda root: $CondaRoot" -ForegroundColor Cyan

$conda = Join-Path $CondaRoot "Scripts\conda.exe"
$mamba = Join-Path $CondaRoot "Scripts\mamba.exe"
$solver = $conda
if (Test-Path $mamba) { $solver = $mamba }
Write-Host "Solver:     $solver" -ForegroundColor Cyan

$envRoot = Join-Path $CondaRoot "envs\$EnvName"

if ((Test-Path $envRoot) -and $Force) {
  Write-Host "-Force: brisem postojeci env $envRoot" -ForegroundColor Yellow
  & $conda env remove -n $EnvName -y
}

if (Test-Path (Join-Path $envRoot "python.exe")) {
  Write-Host "Env vec postoji: $envRoot" -ForegroundColor Green
} else {
  # Dva namjerna izbora radi velicine env-a:
  #  - libgdal-core umjesto punog "gdal" metapaketa: daje gdal_translate i
  #    gdalinfo koji su nam jedini potrebni, bez ostalih drivera
  #  - ceres-solver pinan na CPU build: PDAL ga povlaci, a conda po defaultu
  #    izabere CUDA varijantu koja donese ~1.9 GB nVidia biblioteka koje
  #    ovaj pipeline nikad ne koristi
  Write-Host "Kreiram env '$EnvName' (pdal, libgdal-core, python 3.11)... ovo traje nekoliko minuta." -ForegroundColor Yellow
  & $solver create -n $EnvName -c conda-forge python=3.11 pdal libgdal-core "ceres-solver=*=cpulgpl*" laspy numpy pyproj -y
  if ($LASTEXITCODE -ne 0) { throw "conda create nije uspio (exit $LASTEXITCODE)" }

  # lazrs nije na conda-forge; treba samo laspy-ju za citanje LAZ-a iz Pythona.
  # Sam PDAL cita/pise LAZ preko ugradenog laszipa, pa ovo nije kriticno.
  Write-Host "Instaliram lazrs preko pipa..." -ForegroundColor Yellow
  & (Join-Path $envRoot "python.exe") -m pip install --quiet lazrs
  if ($LASTEXITCODE -ne 0) { Write-Host "  lazrs nije instaliran - nije kriticno za batch." -ForegroundColor Yellow }
}

# --- verifikacija ---
$env:Path = "$envRoot\Library\bin;$envRoot\Scripts;$envRoot;$env:Path"
$env:GDAL_DATA  = "$envRoot\Library\share\gdal"
$env:PROJ_LIB   = "$envRoot\Library\share\proj"

Write-Host ""
Write-Host "--- Verifikacija ---" -ForegroundColor Cyan
$ok = $true
foreach ($t in @(
    @{ Name = "pdal";     Cmd = "$envRoot\Library\bin\pdal.exe";        Arg = "--version" },
    @{ Name = "gdalinfo"; Cmd = "$envRoot\Library\bin\gdalinfo.exe";    Arg = "--version" },
    @{ Name = "gdal_translate"; Cmd = "$envRoot\Library\bin\gdal_translate.exe"; Arg = "--version" },
    @{ Name = "python";   Cmd = "$envRoot\python.exe";                  Arg = "--version" }
  )) {
  if (Test-Path $t.Cmd) {
    $v = (& $t.Cmd $t.Arg 2>&1 | Select-Object -First 1)
    Write-Host ("  {0,-16} OK   {1}" -f $t.Name, $v) -ForegroundColor Green
  } else {
    Write-Host ("  {0,-16} NEDOSTAJE  ({1})" -f $t.Name, $t.Cmd) -ForegroundColor Red
    $ok = $false
  }
}

# provjeri da PDAL ima filters.colorization i writers.las
$stages = & "$envRoot\Library\bin\pdal.exe" --drivers 2>&1 | Out-String
foreach ($s in @("filters.colorization", "writers.las", "readers.las")) {
  if ($stages -match [regex]::Escape($s)) {
    Write-Host ("  {0,-16} OK" -f $s) -ForegroundColor Green
  } else {
    Write-Host ("  {0,-16} NEDOSTAJE" -f $s) -ForegroundColor Red
    $ok = $false
  }
}

Write-Host ""
if ($ok) {
  Write-Host "Env je spreman." -ForegroundColor Green
  Write-Host "Upisi ovo u config.json -> envRoot:" -ForegroundColor Cyan
  Write-Host ("  " + ($envRoot -replace '\\', '\\')) -ForegroundColor White
} else {
  Write-Host "Env NIJE potpun - pogledaj crvene stavke iznad." -ForegroundColor Red
  exit 1
}
