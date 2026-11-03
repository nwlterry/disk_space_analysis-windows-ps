#Requires -Version 5.1
<#
.SYNOPSIS
  Compare two disk-space-analysis folders.csv snapshots.

.DESCRIPTION
  Reads the folders.csv files written by Get-DiskAnalysis.ps1 (or disk-space-analysis.exe)
  and reports which folders grew, shrank, appeared, or disappeared.
  Parent totals include their children, so a new large file shows up on every
  folder above it. Sort is by absolute change. compare.html opens the same
  change screen as the web viewer: earlier, later, net change, then the bars.

.PARAMETER EventLog
  Also write the summary to the Windows Application log. The source name is
  disk-space-analysis. The first run must be elevated so Windows can register
  that source.

.EXAMPLE
  .\Compare-DiskAnalysis.ps1 -Before C:\disk-space-analysis-reports\disk-space-analysis-20261006-folders.csv -After C:\disk-space-analysis-reports\latest-folders.csv -OutDir C:\disk-space-analysis-reports\compare -EventLog
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Before,
  [Parameter(Mandatory = $true)]
  [string]$After,
  [string]$OutDir = '.\disk-space-analysis-compare',
  [int]$Top = 100,
  [long]$MinDeltaBytes = 1MB,
  [switch]$EventLog
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
if ($Top -lt 1) { $Top = 1 }
if ($MinDeltaBytes -lt 0) { $MinDeltaBytes = 0 }

$script:LogWriter = $null
$script:EventReady = $false

function Format-LogText([string]$Message) {
  $text = $Message -replace '[\r\n]+', ' '
  if ($null -eq $text) { return '' }
  return $text
}

function Write-EventNote([string]$Message, [bool]$IsError) {
  if (-not $script:EventReady) { return }
  $text = Format-LogText $Message
  if ($text.Length -gt 30000) { $text = $text.Substring(0, 30000) }
  $type = [System.Diagnostics.EventLogEntryType]::Information
  $id = 1001
  if ($IsError) {
    $type = [System.Diagnostics.EventLogEntryType]::Warning
    $id = 2000
  }
  try {
    $log = New-Object System.Diagnostics.EventLog 'Application'
    $log.Source = 'disk-space-analysis'
    $log.WriteEntry($text, $type, $id)
  } catch {
    $script:EventReady = $false
  }
}

function Write-Note([string]$Message, [switch]$ErrorLine, [switch]$Event) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + (Format-LogText $Message)
  Write-Host $line
  if ($null -ne $script:LogWriter) { $script:LogWriter.WriteLine($line) }
  if ($Event) { Write-EventNote $Message ([bool]$ErrorLine) }
}

function Initialize-RunLog {
  [void][System.IO.Directory]::CreateDirectory($OutDir)
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $script:LogWriter = New-Object System.IO.StreamWriter ((Join-Path $OutDir 'disk-space-analysis.log'), $true, $utf8)
  $script:LogWriter.AutoFlush = $true
  if (-not $EventLog) { return }
  try {
    $source = 'disk-space-analysis'
    if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
      [System.Diagnostics.EventLog]::CreateEventSource($source, 'Application')
    }
    $script:EventReady = $true
  } catch {
    Write-Note ("Windows event log is not available: " + $_.Exception.Message) -ErrorLine
  }
}

Initialize-RunLog
try {

function Read-FolderCsv([string]$FilePath) {
  if (-not (Test-Path -LiteralPath $FilePath)) { throw "File not found: $FilePath" }
  $map = @{}
  $rootBytes = [int64]0
  $rootPath = ''
  $rootSet = $false
  foreach ($row in (Import-Csv -LiteralPath $FilePath)) {
    $path = [string]$row.path
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $logical = [int64]$row.logicalBytes
    $depth = 0
    if ($row.PSObject.Properties.Name -contains 'depth' -and $row.depth -ne '') { $depth = [int]$row.depth }
    $map[$path] = [ordered]@{
      path = $path
      name = [string]$row.name
      logicalBytes = $logical
      depth = $depth
    }
    if ($depth -eq 0 -and (-not $rootSet -or $logical -gt $rootBytes)) {
      $rootBytes = $logical
      $rootPath = $path
      $rootSet = $true
    }
  }
  return @{ Map = $map; RootBytes = $rootBytes; RootPath = $rootPath }
}

function New-Change($Path, $Name, [int64]$BeforeBytes, [int64]$AfterBytes) {
  return [ordered]@{
    path = [string]$Path
    name = [string]$Name
    beforeBytes = $BeforeBytes
    afterBytes = $AfterBytes
    deltaBytes = ($AfterBytes - $BeforeBytes)
  }
}

function Take-Top($Rows, [int]$Limit) {
  $sorted = @($Rows | Sort-Object { [Math]::Abs([int64]$_.deltaBytes) } -Descending)
  $list = New-Object System.Collections.Generic.List[object]
  $n = $sorted.Length
  if ($n -gt $Limit) { $n = $Limit }
  for ($i = 0; $i -lt $n; $i++) { [void]$list.Add($sorted[$i]) }
  return ,$list
}

function Get-StampDate([string]$FilePath) {
  $name = [System.IO.Path]::GetFileName($FilePath)
  if ($name -match '(\d{4})(\d{2})(\d{2})') { return $Matches[1] + '-' + $Matches[2] + '-' + $Matches[3] }
  return (Get-Item -LiteralPath $FilePath).LastWriteTimeUtc.ToString('yyyy-MM-dd')
}

function Format-Byte([int64]$Number) {
  $sign = ''
  $value = [double]$Number
  if ($Number -lt 0) { $sign = '-'; $value = [double](-$Number) }
  $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
  $index = 0
  while ($value -ge 1024 -and $index -lt ($units.Length - 1)) { $value = $value / 1024; $index++ }
  $digits = 0
  if ($index -gt 0) {
    if ($value -ge 100) { $digits = 0 } elseif ($value -ge 10) { $digits = 1 } else { $digits = 2 }
  }
  return $sign + $value.ToString(('F' + $digits), [System.Globalization.CultureInfo]::InvariantCulture) + ' ' + $units[$index]
}

function Format-Signed([int64]$Number) {
  if ($Number -gt 0) { return '+' + (Format-Byte $Number) }
  return Format-Byte $Number
}

function Escape-Html([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $amp = ([char]38) + 'amp;'
  $lt = ([char]38) + 'lt;'
  $gt = ([char]38) + 'gt;'
  $quot = ([char]38) + 'quot;'
  return $Text.Replace(([char]38).ToString(), $amp).Replace('<', $lt).Replace('>', $gt).Replace('"', $quot)
}

function Add-ChangeSection([System.Text.StringBuilder]$Sb, [string]$Title, $Rows, [bool]$Grew) {
  [void]$Sb.Append('<section class="chg"><h2>' + (Escape-Html $Title) + '</h2>')
  $items = @($Rows)
  if ($items.Count -eq 0 -or $null -eq $Rows) {
    [void]$Sb.Append('<p class="hint">None.</p></section>')
    return
  }
  $max = [int64]1
  foreach ($row in $items) {
    $size = [int64][Math]::Abs([int64]$row.deltaBytes)
    if ($size -gt $max) { $max = $size }
  }
  $tone = 'down'
  if ($Grew) { $tone = 'up' }
  foreach ($row in $items) {
    $delta = [int64]$row.deltaBytes
    $width = [int64]([Math]::Abs($delta) * 100 / $max)
    if ($width -lt 2) { $width = 2 }
    [void]$Sb.Append('<div style="margin-bottom:14px"><div class="row"><span class="path" title="' + (Escape-Html ([string]$row.path)) + '">' + (Escape-Html ([string]$row.path)) + '</span><span class="mono ' + $tone + '">' + (Escape-Html (Format-Signed $delta)) + '</span></div>')
    [void]$Sb.Append('<div class="bar"><i class="' + $tone + '" style="width:' + $width + '%"></i></div><div class="hint mono">' + (Escape-Html (Format-Byte ([int64]$row.beforeBytes))) + ' &#8594; ' + (Escape-Html (Format-Byte ([int64]$row.afterBytes))) + '</div></div>')
  }
  [void]$Sb.Append('</section>')
}

function Write-CompareHtml([string]$Target, $Report) {
  $before = $Report.before
  $after = $Report.after
  $delta = [int64]$after.logicalBytes - [int64]$before.logicalBytes
  $netHint = 'Volume shrank'
  if ($delta -ge 0) { $netHint = 'Volume grew' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>disk-space-analysis compare</title><style>')
  [void]$sb.Append(':root{--bg:#10120e;--surface:#1a1d17;--surface2:#23281f;--line:#34392e;--fg:#ebe7dc;--muted:#a39e91;--faint:#746f64;--danger:#d4654a}')
  [void]$sb.Append('*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 Segoe UI,sans-serif}.wrap{max-width:80rem;margin:0 auto;padding:16px}')
  [void]$sb.Append('.kicker{font-family:Consolas,monospace;font-size:12px;letter-spacing:.04em;color:#e0a23a;margin:0}h1{font-size:22px;font-weight:500;margin:2px 0 16px}')
  [void]$sb.Append('.stats{display:grid;grid-template-columns:1fr;gap:8px}@media(min-width:800px){.stats{grid-template-columns:repeat(3,minmax(0,1fr))}}')
  [void]$sb.Append('.stat{border:1px solid var(--line);background:var(--surface);border-radius:8px;padding:12px;min-width:0}.stat b{display:block;margin-top:4px;font-family:Consolas,monospace;font-size:18px;font-weight:500}.stat span,.hint{color:var(--faint);font-size:12px}.hint{color:var(--muted)}')
  [void]$sb.Append('.chg{margin-top:22px}.chg h2{font-size:16px;font-weight:500;margin:0 0 10px}.row{display:flex;justify-content:space-between;gap:12px}.path{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}')
  [void]$sb.Append('.mono{font-family:Consolas,monospace}.up{color:var(--danger)}.down{color:#8aa56e}.bar{height:8px;background:var(--surface2);border-radius:99px;overflow:hidden;margin-top:4px}.bar i{display:block;height:100%}.bar i.up{background:var(--danger)}.bar i.down{background:#8aa56e}')
  [void]$sb.Append('</style></head><body><div class="wrap"><p class="kicker">DISK-SPACE-ANALYSIS</p><h1>Disk space analysis</h1><div class="stats">')
  foreach ($card in @(
      @{ label = 'Earlier'; value = (Format-Byte ([int64]$before.logicalBytes)); hint = (([string]$before.label) + $(if ($before.scannedAt) { ' | ' + $before.scannedAt } else { '' })) },
      @{ label = 'Later'; value = (Format-Byte ([int64]$after.logicalBytes)); hint = (([string]$after.label) + $(if ($after.scannedAt) { ' | ' + $after.scannedAt } else { '' })) },
      @{ label = 'Net change'; value = (Format-Signed $delta); hint = $netHint }
    )) {
    [void]$sb.Append('<div class="stat"><span>' + (Escape-Html $card.label) + '</span><b>' + (Escape-Html $card.value) + '</b><div class="hint">' + (Escape-Html $card.hint) + '</div></div>')
  }
  [void]$sb.Append('</div>')
  Add-ChangeSection $sb 'Grew' $Report.grew $true
  Add-ChangeSection $sb 'Shrank' $Report.shrunk $false
  Add-ChangeSection $sb 'Added' $Report.added $true
  Add-ChangeSection $sb 'Removed' $Report.removed $false
  [void]$sb.Append('</div></body></html>')
  $utf8Bom = New-Object System.Text.UTF8Encoding $true
  [System.IO.File]::WriteAllText($Target, $sb.ToString(), $utf8Bom)
}

$beforeSet = Read-FolderCsv $Before
$afterSet = Read-FolderCsv $After
$grew = New-Object System.Collections.Generic.List[object]
$shrunk = New-Object System.Collections.Generic.List[object]
$added = New-Object System.Collections.Generic.List[object]
$removed = New-Object System.Collections.Generic.List[object]

foreach ($path in @($afterSet.Map.Keys)) {
  $afterRow = $afterSet.Map[$path]
  if ($beforeSet.Map.ContainsKey($path)) {
    $beforeRow = $beforeSet.Map[$path]
    $delta = [int64]$afterRow.logicalBytes - [int64]$beforeRow.logicalBytes
    if ([Math]::Abs($delta) -lt $MinDeltaBytes) { continue }
    $change = New-Change $path $afterRow.name ([int64]$beforeRow.logicalBytes) ([int64]$afterRow.logicalBytes)
    if ($delta -gt 0) { [void]$grew.Add($change) } else { [void]$shrunk.Add($change) }
  } else {
    if ([int64]$afterRow.logicalBytes -lt $MinDeltaBytes) { continue }
    [void]$added.Add((New-Change $path $afterRow.name 0 ([int64]$afterRow.logicalBytes)))
  }
}
foreach ($path in @($beforeSet.Map.Keys)) {
  if ($afterSet.Map.ContainsKey($path)) { continue }
  $beforeRow = $beforeSet.Map[$path]
  if ([int64]$beforeRow.logicalBytes -lt $MinDeltaBytes) { continue }
  [void]$removed.Add((New-Change $path $beforeRow.name ([int64]$beforeRow.logicalBytes) 0))
}

$grewTop = Take-Top $grew $Top
$shrunkTop = Take-Top $shrunk $Top
$addedTop = Take-Top $added $Top
$removedTop = Take-Top $removed $Top

$report = [ordered]@{
  kind = 'compare'
  tool = 'disk-space-analysis.compare'
  version = '1.0'
  generatedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  before = [ordered]@{
    label = $(if ($beforeSet.RootPath) { [string]$beforeSet.RootPath } else { [string](Resolve-Path -LiteralPath $Before) })
    scannedAt = (Get-StampDate $Before)
    logicalBytes = [int64]$beforeSet.RootBytes
  }
  after = [ordered]@{
    label = $(if ($afterSet.RootPath) { [string]$afterSet.RootPath } else { [string](Resolve-Path -LiteralPath $After) })
    scannedAt = (Get-StampDate $After)
    logicalBytes = [int64]$afterSet.RootBytes
  }
  grew = $grewTop
  shrunk = $shrunkTop
  added = $addedTop
  removed = $removedTop
}

function Append-JsonString([System.Text.StringBuilder]$Sb, [string]$Text) {
  [void]$Sb.Append('"')
  foreach ($ch in $Text.ToCharArray()) {
    $code = [int]$ch
    if ($code -eq 34) { [void]$Sb.Append('\"'); continue }
    if ($code -eq 92) { [void]$Sb.Append('\\'); continue }
    if ($code -eq 8) { [void]$Sb.Append('\b'); continue }
    if ($code -eq 10) { [void]$Sb.Append('\n'); continue }
    if ($code -eq 13) { [void]$Sb.Append('\r'); continue }
    if ($code -eq 9) { [void]$Sb.Append('\t'); continue }
    if ($code -lt 32) { [void]$Sb.Append('\u'); [void]$Sb.Append($code.ToString('x4')); continue }
    [void]$Sb.Append($ch)
  }
  [void]$Sb.Append('"')
}

function Append-Json([System.Text.StringBuilder]$Sb, $Value) {
  if ($null -eq $Value) { [void]$Sb.Append('null'); return }
  if ($Value -is [string]) { Append-JsonString $Sb $Value; return }
  if ($Value -is [bool]) {
    if ($Value) { [void]$Sb.Append('true') } else { [void]$Sb.Append('false') }
    return
  }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
    [void]$Sb.Append([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
    return
  }
  if ($Value -is [System.Collections.IDictionary]) {
    [void]$Sb.Append('{')
    $first = $true
    foreach ($key in @($Value.Keys)) {
      if (-not $first) { [void]$Sb.Append(',') }
      $first = $false
      Append-JsonString $Sb ([string]$key)
      [void]$Sb.Append(':')
      Append-Json $Sb $Value[$key]
    }
    [void]$Sb.Append('}')
    return
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    [void]$Sb.Append('[')
    $first = $true
    foreach ($item in $Value) {
      if (-not $first) { [void]$Sb.Append(',') }
      $first = $false
      Append-Json $Sb $item
    }
    [void]$Sb.Append(']')
    return
  }
  Append-JsonString $Sb ([string]$Value)
}

[void][System.IO.Directory]::CreateDirectory($OutDir)
$sb = New-Object System.Text.StringBuilder
Append-Json $sb $report
$utf8 = New-Object System.Text.UTF8Encoding $false
$jsonPath = Join-Path $OutDir 'compare.json'
$htmlPath = Join-Path $OutDir 'compare.html'
[System.IO.File]::WriteAllText($jsonPath, $sb.ToString(), $utf8)
Write-CompareHtml $htmlPath $report

function Write-ChangeCsv([string]$Target, $Rows) {
  $lines = New-Object System.Text.StringBuilder
  [void]$lines.AppendLine('path,name,beforeBytes,afterBytes,deltaBytes')
  foreach ($row in $Rows) {
    $path = '"' + ([string]$row.path).Replace('"', '""') + '"'
    $name = '"' + ([string]$row.name).Replace('"', '""') + '"'
    [void]$lines.AppendLine(($path + ',' + $name + ',' + $row.beforeBytes + ',' + $row.afterBytes + ',' + $row.deltaBytes))
  }
  $bom = New-Object System.Text.UTF8Encoding $true
  [System.IO.File]::WriteAllText($Target, $lines.ToString(), $bom)
}

Write-ChangeCsv (Join-Path $OutDir 'grew.csv') $grewTop
Write-ChangeCsv (Join-Path $OutDir 'shrunk.csv') $shrunkTop
Write-ChangeCsv (Join-Path $OutDir 'added.csv') $addedTop
Write-ChangeCsv (Join-Path $OutDir 'removed.csv') $removedTop

$delta = [int64]$afterSet.RootBytes - [int64]$beforeSet.RootBytes
Write-Note ("Net {0} bytes. Grew {1}, shrunk {2}, added {3}, removed {4}." -f $delta, $grewTop.Count, $shrunkTop.Count, $addedTop.Count, $removedTop.Count) -Event
Write-Note ("Wrote {0} and {1}. Log {2}" -f $jsonPath, $htmlPath, (Join-Path $OutDir 'disk-space-analysis.log')) -Event
} catch {
  Write-Note $_.Exception.Message -ErrorLine -Event
  exit 1
} finally {
  if ($null -ne $script:LogWriter) {
    $script:LogWriter.Dispose()
    $script:LogWriter = $null
  }
}
exit 0
