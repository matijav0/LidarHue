<#
.SYNOPSIS
  Batch bojanje DGU LiDAR (.las/.laz) datoteka pomocu DGU ortofoto WMS-a.

.DESCRIPTION
  Za svaki ulazni tile:
    1. procita bounding box iz headera preko `pdal info --summary`
    2. skine ortofoto GeoTIFF iz DGU WMS-a za tocno taj bbox
    3. napravi "colored" izlaz preko PDAL filters.colorization
    4. skine POMAKNUTI siri raster tako da WMS watermark (koji je u sredini
       slike) padne izvan tilea, pa ga izreze natrag na tile
    5. napravi "no_center_watermark" izlaz
    6. (opcionalno) premjesti obradeni ulaz u inputi_obradjeni

  Sve postavke su u config.json u rootu projekta. Skripta vodi log datoteku
  i status CSV, pa se prekinuti batch moze nastaviti bez ponavljanja gotovog.

.EXAMPLE
  # provjera okruzenja i konfiguracije, bez ijednog requesta
  .\backend\scripts\process_lidar_batch.ps1 -DryRun

  # jedan fajl, za test
  .\backend\scripts\process_lidar_batch.ps1 -MaxFiles 1

  # samo jedna grupa
  .\backend\scripts\process_lidar_batch.ps1 -GroupFilter Lidar_data

  # cijeli batch
  .\backend\scripts\process_lidar_batch.ps1
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = "",
  [string]$GroupFilter = "",
  [string]$FileFilter = "",
  [int]$MaxFiles = 0,
  [double]$Resolution = 0,
  [double]$ShiftFactor = 0,
  [ValidateSet("colored", "no_center_watermark", "both")]
  [string]$Variants = "both",
  [switch]$Force,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

# ============================================================================
# Putanje i konfiguracija
# ============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path

if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $Root "config.json" }
if (-not (Test-Path $ConfigPath)) { throw "Ne postoji config: $ConfigPath" }

$Cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($Resolution  -gt 0) { $Cfg.resolution  = $Resolution }
if ($ShiftFactor -gt 0) { $Cfg.shiftFactor = $ShiftFactor }

function Resolve-ProjectPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $null }
  if ($p -match '^(\\\\|[A-Za-z]:)') { return $p }
  return (Join-Path $Root $p)
}

$DirLogs      = Resolve-ProjectPath $Cfg.paths.logs
$DirStatus    = Resolve-ProjectPath $Cfg.paths.status
$DirRasters   = Resolve-ProjectPath $Cfg.paths.rasters
$DirPipelines = Resolve-ProjectPath $Cfg.paths.pipelines
$DirOutputs   = Resolve-ProjectPath $Cfg.paths.outputs
$DirProcessed = Resolve-ProjectPath $Cfg.paths.processed

foreach ($d in @($DirLogs, $DirStatus, $DirRasters, $DirPipelines, $DirOutputs, $DirProcessed)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ============================================================================
# Logging
# ============================================================================

$RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile  = Join-Path $DirLogs "batch_$RunStamp.log"

function Write-Log {
  # Message NE smije biti Mandatory: `Write-Log ""` bi tada zatrazio unos s
  # tipkovnice i zablokirao cijeli batch.
  param(
    [AllowEmptyString()][string]$Message = "",
    [ValidateSet("INFO", "WARN", "ERROR", "OK", "STEP")][string]$Level = "INFO"
  )
  $ts   = Get-Date -Format "HH:mm:ss"
  $line = "[$ts][$Level] $Message"

  # Pisanje u log NE SMIJE srusiti batch. Ako netko drzi datoteku otvorenom
  # (tail -f, editor, antivirus), Add-Content baci IOException koja bi uz
  # $ErrorActionPreference="Stop" prekinula visesatnu obradu. Zato retry pa
  # tiho odustajanje - konzolni ispis svejedno ostaje.
  for ($a = 1; $a -le 3; $a++) {
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop; break }
    catch { if ($a -eq 3) { } else { Start-Sleep -Milliseconds (150 * $a) } }
  }

  $color = "Gray"
  switch ($Level) {
    "OK"    { $color = "Green" }
    "WARN"  { $color = "Yellow" }
    "ERROR" { $color = "Red" }
    "STEP"  { $color = "Cyan" }
  }
  Write-Host $line -ForegroundColor $color
}

# ============================================================================
# Conda env / alati
# ============================================================================

$EnvRoot = $Cfg.envRoot
if (-not (Test-Path $EnvRoot)) {
  throw "envRoot ne postoji: $EnvRoot`nPokreni backend\scripts\setup_env.ps1 pa ispravi config.json."
}

$env:Path      = "$EnvRoot\Library\bin;$EnvRoot\Scripts;$EnvRoot;$env:Path"
$env:GDAL_DATA = "$EnvRoot\Library\share\gdal"
$env:PROJ_LIB  = "$EnvRoot\Library\share\proj"

$PdalExe     = Join-Path $EnvRoot "Library\bin\pdal.exe"
$GdalTransExe = Join-Path $EnvRoot "Library\bin\gdal_translate.exe"

foreach ($exe in @($PdalExe, $GdalTransExe)) {
  if (-not (Test-Path $exe)) { throw "Nedostaje alat: $exe`nPokreni backend\scripts\setup_env.ps1." }
}

# ============================================================================
# Status CSV (resume)
# ============================================================================

$StatusFile = Join-Path $DirStatus "status.csv"
$StatusMap  = @{}

function Get-StatusKey([string]$group, [string]$file) { return "$group|$file" }

function Import-Status {
  $script:StatusMap = @{}
  if (Test-Path $StatusFile) {
    foreach ($row in (Import-Csv $StatusFile)) {
      $script:StatusMap[(Get-StatusKey $row.group $row.file)] = $row
    }
  }
}

function Set-Status {
  param([string]$Group, [string]$File, [string]$Variant, [string]$State, [string]$Message = "")
  $key = Get-StatusKey $Group $File
  if (-not $StatusMap.ContainsKey($key)) {
    $StatusMap[$key] = [pscustomobject]@{
      group               = $Group
      file                = $File
      colored             = "pending"
      no_center_watermark = "pending"
      updated             = ""
      message             = ""
    }
  }
  $r = $StatusMap[$key]
  if ($Variant) { $r.$Variant = $State }
  $r.updated = (Get-Date -Format "s")
  $r.message = $Message
  $StatusMap[$key] = $r
}

function Save-Status {
  $StatusMap.Values |
    Sort-Object group, file |
    Export-Csv -Path $StatusFile -NoTypeInformation -Encoding UTF8
}

Import-Status

# ============================================================================
# Geometrija i WMS
# ============================================================================

function Get-LasBounds {
  param([Parameter(Mandatory = $true)][string]$Path)
  # stderr se namjerno NE spaja sa stdoutom - pdal ponekad pise upozorenja
  # koja bi razbila ConvertFrom-Json
  $json = & $PdalExe info --summary "$Path" | Out-String
  if ($LASTEXITCODE -ne 0) { throw "pdal info nije uspio za '$Path' (exit $LASTEXITCODE)" }
  try { $obj = $json | ConvertFrom-Json }
  catch { throw "pdal info nije vratio ispravan JSON za '$Path': $json" }
  $b = $obj.summary.bounds
  return [pscustomobject]@{
    MinX   = [double]$b.minx
    MinY   = [double]$b.miny
    MaxX   = [double]$b.maxx
    MaxY   = [double]$b.maxy
    Width  = [double]$b.maxx - [double]$b.minx
    Height = [double]$b.maxy - [double]$b.miny
    Points = [long]$obj.summary.num_points
  }
}

# Vrati piksel-dimenzije za zadani opseg, uz clamp na maxPixelsPerSide.
# Ako bi request bio prevelik, rezolucija se automatski pogrubi.
function Get-RequestSize {
  param([double]$SpanX, [double]$SpanY, [double]$Res)
  $maxPx = [int]$Cfg.maxPixelsPerSide
  $w = [math]::Ceiling($SpanX / $Res)
  $h = [math]::Ceiling($SpanY / $Res)
  $effRes = $Res
  if ($w -gt $maxPx -or $h -gt $maxPx) {
    $scale  = [math]::Max($w / $maxPx, $h / $maxPx)
    $effRes = $Res * $scale
    $w = [math]::Ceiling($SpanX / $effRes)
    $h = [math]::Ceiling($SpanY / $effRes)
    Write-Log "Request prevelik uz res=$Res m -> koristim res=$([math]::Round($effRes,3)) m ($w x $h px)" "WARN"
  }
  return [pscustomobject]@{ Width = [int]$w; Height = [int]$h; Res = $effRes }
}

function New-WmsUrl {
  param(
    [double]$MinX, [double]$MinY, [double]$MaxX, [double]$MaxY,
    [int]$Width, [int]$Height
  )
  # EPSG:3765 (HTRS96 / Croatia TM) ima axis order Easting,Northing pa u
  # WMS 1.3.0 BBOX ostaje minx,miny,maxx,maxy. axisOrder="yx" u configu
  # zamijeni redoslijed ako se servis ikad ponasa drukcije.
  # ToString(InvariantCulture) je obavezan: na hrvatskom localeu bi "{0}" -f
  # dalo decimalni zarez i razbilo BBOX parametar.
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  if ($Cfg.wms.axisOrder -eq "yx") {
    $bbox = "$($MinY.ToString($inv)),$($MinX.ToString($inv)),$($MaxY.ToString($inv)),$($MaxX.ToString($inv))"
  } else {
    $bbox = "$($MinX.ToString($inv)),$($MinY.ToString($inv)),$($MaxX.ToString($inv)),$($MaxY.ToString($inv))"
  }

  $q = @(
    "SERVICE=WMS",
    "VERSION=$($Cfg.wms.version)",
    "REQUEST=GetMap",
    "LAYERS=$([uri]::EscapeDataString($Cfg.wms.layer))",
    "STYLES=$($Cfg.wms.styles)",
    "CRS=$($Cfg.crs)",
    "BBOX=$bbox",
    "WIDTH=$Width",
    "HEIGHT=$Height",
    "FORMAT=$([uri]::EscapeDataString($Cfg.wms.format))",
    "TRANSPARENT=FALSE"
  ) -join "&"

  $sep = "?"
  if ($Cfg.wms.base.Contains("?")) { $sep = "&" }
  return "$($Cfg.wms.base)$sep$q"
}

# Provjeri je li skinuta datoteka stvarno TIFF, a ne WMS ServiceException XML.
function Test-IsTiff {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return $false }
  $fi = Get-Item $Path
  if ($fi.Length -lt 1024) { return $false }
  $bytes = Get-Content -Path $Path -Encoding Byte -TotalCount 4
  # "II*\0" (little endian) ili "MM\0*" (big endian); BigTIFF: II+\0 / MM\0+
  if ($bytes[0] -eq 0x49 -and $bytes[1] -eq 0x49) { return $true }
  if ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x4D) { return $true }
  return $false
}

function Get-WmsRaster {
  param([string]$Url, [string]$OutFile)

  $attempts = [int]$Cfg.retry.count
  $delay    = [int]$Cfg.retry.delaySeconds

  for ($i = 1; $i -le $attempts; $i++) {
    try {
      if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
      Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 600
      if (Test-IsTiff $OutFile) {
        $mb = [math]::Round((Get-Item $OutFile).Length / 1MB, 2)
        Write-Log "  raster OK ($mb MB)" "OK"
        return $true
      }
      # servis je vratio nesto sto nije TIFF - najcesce XML exception
      $head = ""
      if (Test-Path $OutFile) {
        $head = (Get-Content $OutFile -Raw -ErrorAction SilentlyContinue)
        if ($head.Length -gt 400) { $head = $head.Substring(0, 400) }
      }
      Write-Log "  pokusaj $i/$attempts - odgovor nije TIFF: $($head -replace '\s+',' ')" "WARN"
    } catch {
      Write-Log "  pokusaj $i/$attempts - greska: $($_.Exception.Message)" "WARN"
    }
    if ($i -lt $attempts) { Start-Sleep -Seconds ($delay * $i) }
  }
  if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
  return $false
}

# Dodijeli georeferencu (i po potrebi izrezi) bez oslanjanja na WMS-ov header.
function Set-RasterGeoreference {
  param(
    [string]$InFile, [string]$OutFile,
    [double]$MinX, [double]$MinY, [double]$MaxX, [double]$MaxY,
    [int[]]$SrcWin = $null
  )
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  # -srcwin rezuce piksele, -a_ullr dodjeljuje georeferencu rezultatu; time
  # smo potpuno neovisni o tome sto WMS upise u svoj GeoTIFF header.
  $gdalArgs = @("-q", "-of", "GTiff",
                "-a_srs", $Cfg.crs,
                "-a_ullr", $MinX.ToString($inv), $MaxY.ToString($inv), $MaxX.ToString($inv), $MinY.ToString($inv),
                "-co", "TILED=YES", "-co", "COMPRESS=DEFLATE")
  if ($SrcWin) {
    $gdalArgs += @("-srcwin", "$($SrcWin[0])", "$($SrcWin[1])", "$($SrcWin[2])", "$($SrcWin[3])")
  }
  $gdalArgs += @($InFile, $OutFile)

  if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
  & $GdalTransExe @gdalArgs
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutFile)) {
    throw "gdal_translate nije uspio ($LASTEXITCODE): $OutFile"
  }
}

# ============================================================================
# PDAL colorization
# ============================================================================

function Invoke-Colorize {
  param(
    [string]$InLas, [string]$Raster, [string]$OutLas, [string]$PipelineJson
  )

  # Nedovrsen izlaz pise se u .part pa se tek na kraju preimenuje, da prekid
  # batcha (ili zaglavljen pdal) ne ostavi 0-bajtni fajl koji resume smatra gotovim.
  $part = "$OutLas.part"
  if (Test-Path $part) { Remove-Item $part -Force }

  function New-PipelineObject([string]$Target) {
    return @{
      pipeline = @(
        @{ type = "readers.las"; filename = $InLas },
        @{
          type       = "filters.colorization"
          raster     = $Raster
          dimensions = "Red:1:256.0, Green:2:256.0, Blue:3:256.0"
        },
        @{
          type          = "writers.las"
          filename      = $Target
          compression   = $Cfg.output.compression
          minor_version = [int]$Cfg.output.minorVersion
          dataformat_id = [int]$Cfg.output.dataformatId
          a_srs         = $Cfg.crs
          forward       = "scale_x,scale_y,scale_z,offset_x,offset_y,offset_z"
        }
      )
    }
  }

  # jedan JSON se cuva za debug (s konacnim imenom), drugi se stvarno izvrsava
  (New-PipelineObject $OutLas) | ConvertTo-Json -Depth 8 | Set-Content -Path $PipelineJson -Encoding UTF8
  $partJson = "$PipelineJson.part.json"
  (New-PipelineObject $part)   | ConvertTo-Json -Depth 8 | Set-Content -Path $partJson     -Encoding UTF8

  $out = & $PdalExe pipeline "$partJson" 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    if (Test-Path $part) { Remove-Item $part -Force -ErrorAction SilentlyContinue }
    throw "pdal pipeline nije uspio ($LASTEXITCODE): $out"
  }
  if (-not (Test-Path $part) -or (Get-Item $part).Length -lt 1024) {
    if (Test-Path $part) { Remove-Item $part -Force -ErrorAction SilentlyContinue }
    throw "pdal je zavrsio bez greske ali izlaz je prazan: $part"
  }

  if (Test-Path $OutLas) { Remove-Item $OutLas -Force }
  Move-Item $part $OutLas
  Remove-Item $partJson -Force -ErrorAction SilentlyContinue

  $mb = [math]::Round((Get-Item $OutLas).Length / 1MB, 2)
  Write-Log "  izlaz OK ($mb MB): $(Split-Path -Leaf $OutLas)" "OK"
}

# ============================================================================
# Obrada jednog tilea
# ============================================================================

function Invoke-Tile {
  param([string]$GroupName, [System.IO.FileInfo]$InFile)

  $base = [System.IO.Path]::GetFileNameWithoutExtension($InFile.Name)
  $ext  = $Cfg.output.extension

  $outColored = Join-Path (Join-Path $DirOutputs "$GroupName\colored")             "$base$ext"
  $outNoWm    = Join-Path (Join-Path $DirOutputs "$GroupName\no_center_watermark") "$base$ext"
  $rasterDir  = Join-Path $DirRasters   $GroupName
  $pipeDir    = Join-Path $DirPipelines $GroupName
  foreach ($d in @((Split-Path $outColored), (Split-Path $outNoWm), $rasterDir, $pipeDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  }

  $doColored = ($Variants -eq "both" -or $Variants -eq "colored")
  $doNoWm    = ($Variants -eq "both" -or $Variants -eq "no_center_watermark")

  if (-not $Force) {
    if ($doColored -and (Test-Path $outColored) -and (Get-Item $outColored).Length -gt 1024) {
      Write-Log "  colored vec postoji - preskacem" "INFO"; $doColored = $false
    }
    if ($doNoWm -and (Test-Path $outNoWm) -and (Get-Item $outNoWm).Length -gt 1024) {
      Write-Log "  no_center_watermark vec postoji - preskacem" "INFO"; $doNoWm = $false
    }
  }

  if (-not $doColored -and -not $doNoWm) { return "skipped" }

  $b = Get-LasBounds -Path $InFile.FullName
  Write-Log ("  bbox: {0:F1} {1:F1} .. {2:F1} {3:F1}  ({4:F0} x {5:F0} m, {6:N0} tocaka)" -f `
             $b.MinX, $b.MinY, $b.MaxX, $b.MaxY, $b.Width, $b.Height, $b.Points)

  if ($b.Width -le 0 -or $b.Height -le 0) { throw "Degeneriran bbox u headeru." }
  if ($b.MinX -lt 200000 -or $b.MinX -gt 800000 -or $b.MinY -lt 4600000 -or $b.MinY -gt 5300000) {
    Write-Log "  bbox ne izgleda kao EPSG:3765 - provjeri CRS ulaza!" "WARN"
  }

  $res = [double]$Cfg.resolution
  $anyFail = $false

  # ---- 1) colored: raster tocno preko tilea -------------------------------
  if ($doColored) {
    Write-Log "  [1/2] colored" "STEP"
    $sz  = Get-RequestSize -SpanX $b.Width -SpanY $b.Height -Res $res
    $url = New-WmsUrl -MinX $b.MinX -MinY $b.MinY -MaxX $b.MaxX -MaxY $b.MaxY -Width $sz.Width -Height $sz.Height
    $rawTif = Join-Path $rasterDir "$base`_raw.tif"
    $geoTif = Join-Path $rasterDir "$base`_ortho.tif"

    if ($DryRun) {
      Write-Log "  DRYRUN GetMap ($($sz.Width)x$($sz.Height)): $url"
    } else {
      if (Get-WmsRaster -Url $url -OutFile $rawTif) {
        Set-RasterGeoreference -InFile $rawTif -OutFile $geoTif `
          -MinX $b.MinX -MinY $b.MinY -MaxX $b.MaxX -MaxY $b.MaxY
        Remove-Item $rawTif -Force -ErrorAction SilentlyContinue
        Invoke-Colorize -InLas $InFile.FullName -Raster $geoTif -OutLas $outColored `
          -PipelineJson (Join-Path $pipeDir "$base`_colored.json")
        Set-Status -Group $GroupName -File $InFile.Name -Variant "colored" -State "done"
        if (-not $Cfg.output.keepRasters) { Remove-Item $geoTif -Force -ErrorAction SilentlyContinue }
      } else {
        Write-Log "  colored: WMS nije vratio raster" "ERROR"
        Set-Status -Group $GroupName -File $InFile.Name -Variant "colored" -State "failed" -Message "WMS raster fail"
        $anyFail = $true
      }
    }
  }

  # ---- 2) no_center_watermark: pomaknut siri raster, pa crop -------------
  if ($doNoWm) {
    Write-Log "  [2/2] no_center_watermark" "STEP"
    $sf = [double]$Cfg.shiftFactor
    if ($sf -le 2.0) {
      Write-Log "  shiftFactor <= 2.0 znaci da watermark pada na sam rub tilea" "WARN"
    }

    # DGU watermark ("GEOPORTAL") crta se preko CIJELE sirine slike, centriran
    # VERTIKALNO, i pojavljuje se tocno jednom (provjereno do omjera 1:6).
    # Zato sirenje po X-u ne pomaze - trosi piksele bez ucinka. Dovoljno je
    # produziti request po Y i staviti tile na DNO: sredina requesta (watermark)
    # tada padne iznad tilea. Cijena je sf puta vise piksela umjesto sf^2.
    $reqMinX = $b.MinX
    $reqMaxX = $b.MaxX
    $reqMinY = $b.MinY
    $reqMaxY = $b.MinY + ($b.Height * $sf)

    $sz  = Get-RequestSize -SpanX ($reqMaxX - $reqMinX) -SpanY ($reqMaxY - $reqMinY) -Res $res
    $url = New-WmsUrl -MinX $reqMinX -MinY $reqMinY -MaxX $reqMaxX -MaxY $reqMaxY -Width $sz.Width -Height $sz.Height

    $rawTif = Join-Path $rasterDir "$base`_wide_raw.tif"
    $cropTif = Join-Path $rasterDir "$base`_ortho_nowm.tif"

    if ($DryRun) {
      Write-Log "  DRYRUN GetMap ($($sz.Width)x$($sz.Height)): $url"
    } else {
      if (Get-WmsRaster -Url $url -OutFile $rawTif) {
        # izracunaj srcwin iz poznatog requesta - ne oslanjamo se na WMS header
        $pxX = ($reqMaxX - $reqMinX) / $sz.Width
        $pxY = ($reqMaxY - $reqMinY) / $sz.Height
        $xoff = [int][math]::Round(($b.MinX - $reqMinX) / $pxX)
        $yoff = [int][math]::Round(($reqMaxY - $b.MaxY) / $pxY)
        $xs   = [int][math]::Round($b.Width  / $pxX)
        $ys   = [int][math]::Round($b.Height / $pxY)
        if ($xs -lt 1) { $xs = 1 }
        if ($ys -lt 1) { $ys = 1 }

        Set-RasterGeoreference -InFile $rawTif -OutFile $cropTif `
          -MinX $b.MinX -MinY $b.MinY -MaxX $b.MaxX -MaxY $b.MaxY `
          -SrcWin @($xoff, $yoff, $xs, $ys)
        Remove-Item $rawTif -Force -ErrorAction SilentlyContinue

        Invoke-Colorize -InLas $InFile.FullName -Raster $cropTif -OutLas $outNoWm `
          -PipelineJson (Join-Path $pipeDir "$base`_nowm.json")
        Set-Status -Group $GroupName -File $InFile.Name -Variant "no_center_watermark" -State "done"
        if (-not $Cfg.output.keepRasters) { Remove-Item $cropTif -Force -ErrorAction SilentlyContinue }
      } else {
        Write-Log "  no_center_watermark: WMS nije vratio raster (probaj manji shiftFactor ili veci resolution)" "ERROR"
        Set-Status -Group $GroupName -File $InFile.Name -Variant "no_center_watermark" -State "failed" -Message "WMS raster fail"
        $anyFail = $true
      }
    }
  }

  if ($anyFail) { return "failed" }
  return "done"
}

# ============================================================================
# Glavna petlja
# ============================================================================

Write-Log "=== DGU point cloud colorization ===" "STEP"
Write-Log "root:        $Root"
Write-Log "config:      $ConfigPath"
Write-Log "env:         $EnvRoot"
Write-Log "log:         $LogFile"
Write-Log "resolution:  $($Cfg.resolution) m   shiftFactor: $($Cfg.shiftFactor)   variants: $Variants"
if ($DryRun) { Write-Log "DRY RUN - nista se ne skida i ne pise" "WARN" }

$groups = $Cfg.groups
if ($GroupFilter) { $groups = $groups | Where-Object { $_.name -like $GroupFilter } }
if (-not $groups) { throw "Nijedna grupa ne odgovara filteru '$GroupFilter'." }

$totDone = 0; $totFail = 0; $totSkip = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($g in $groups) {
  $src = Resolve-ProjectPath $g.source
  Write-Log ""
  Write-Log "--- Grupa: $($g.name)  <- $src" "STEP"

  if (-not (Test-Path $src)) {
    Write-Log "Izvor ne postoji, preskacem grupu: $src" "WARN"
    continue
  }

  $files = @(Get-ChildItem -Path $src -File -Recurse -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -in ".las", ".laz" })
  if ($FileFilter) { $files = @($files | Where-Object { $_.Name -like $FileFilter }) }
  $files = @($files | Sort-Object Name)

  if ($files.Count -eq 0) { Write-Log "Nema .las/.laz datoteka u $src" "WARN"; continue }
  if ($MaxFiles -gt 0 -and $files.Count -gt $MaxFiles) { $files = $files[0..($MaxFiles - 1)] }

  Write-Log "Datoteka za obradu: $($files.Count)"

  $i = 0
  foreach ($f in $files) {
    $i++
    $mb = [math]::Round($f.Length / 1MB, 1)
    Write-Log ""
    Write-Log "[$i/$($files.Count)] $($f.Name)  ($mb MB)" "STEP"

    try {
      $r = Invoke-Tile -GroupName $g.name -InFile $f
      switch ($r) {
        "done"    { $totDone++ }
        "failed"  { $totFail++ }
        "skipped" { $totSkip++ }
      }

      $moveWhenDone = $false
      if ($g.PSObject.Properties.Name -contains "moveWhenDone") { $moveWhenDone = [bool]$g.moveWhenDone }
      if ($r -eq "done" -and $moveWhenDone -and -not $DryRun) {
        $dst = Join-Path $DirProcessed "$($g.name)\laz"
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Force -Path $dst | Out-Null }
        Move-Item $f.FullName (Join-Path $dst $f.Name) -Force
        Write-Log "  ulaz premjesten u $dst" "INFO"
      }
    } catch {
      $totFail++
      Write-Log "  NEUSPJEH: $($_.Exception.Message)" "ERROR"
      Set-Status -Group $g.name -File $f.Name -Variant "" -State "" -Message $_.Exception.Message
    }

    if (-not $DryRun) { Save-Status }
  }
}

$sw.Stop()
Write-Log ""
Write-Log "=== Gotovo za $([math]::Round($sw.Elapsed.TotalMinutes,1)) min ===" "STEP"
Write-Log "done: $totDone   failed: $totFail   skipped: $totSkip" "OK"
Write-Log "izlazi:  $DirOutputs"
Write-Log "status:  $StatusFile"
Write-Log "log:     $LogFile"

if ($totFail -gt 0) { exit 1 }
