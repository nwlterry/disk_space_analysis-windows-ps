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

function Write-CompareHtml([string]$Target, [string]$Json) {
  $templatePath = Join-Path $PSScriptRoot 'viewer.html'
  $safe = $Json.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
  $embed = '<script id="disk-space-analysis-embed" type="application/json">' + $safe + '</script>'
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $utf8Bom = New-Object System.Text.UTF8Encoding $true
  if (Test-Path -LiteralPath $templatePath) {
    $template = [System.IO.File]::ReadAllText($templatePath, $utf8)
    if ($template.Contains('<!--DISK_SPACE_ANALYSIS_EMBED-->')) {
      $html = $template.Replace('<!--DISK_SPACE_ANALYSIS_EMBED-->', $embed)
    } else {
      $html = $template
    }
  } else {
    $html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>disk-space-analysis</title></head><body><p>viewer.html was not next to the script.</p>' + $embed + '</body></html>'
  }
  [System.IO.File]::WriteAllText($Target, $html, $utf8Bom)
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
Write-CompareHtml $htmlPath $sb.ToString()

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
