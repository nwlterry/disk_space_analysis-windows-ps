#Requires -Version 5.1
<#
.SYNOPSIS
  disk-space-analysis disk analysis for Windows Server 2016 and later (Windows PowerShell 5.1).

.DESCRIPTION
  Scans one or more folders, volumes, or UNC paths and writes a Tree Size style report:
  folder tree, largest files, extension mix, age, optional duplicates, and
  access errors. Open latest.json in the disk-space-analysis viewer, or double-click
  latest.html for the same screen offline.

  Junctions and symlinks are not followed. -AllocatedSize reads NTFS
  allocation (compression and sparse files included) and is slower.

.PARAMETER Path
  One or more directories. Local paths or UNC. Separate with commas:
  -Path D:\,E:\Shares

.PARAMETER OutDir
  Report folder. Stamped copies plus latest.* files are written here.

.PARAMETER Depth
  How many directory levels to descend. 0 means the whole tree.

.PARAMETER ExportDepth
  How deep the JSON folder tree nests. Deeper folders stay in the totals
  and in folders.csv, but are not expandable in the viewer.

.PARAMETER EventLog
  Also write the start, errors, and the summary to the Windows Application log.
  The source name is disk-space-analysis. The first run must be elevated so
  Windows can register that source. The log file is written either way.

.PARAMETER Quiet
  Hide console progress. The log file in the report folder is still written.

.EXAMPLE
  .\Get-DiskAnalysis.ps1 -Path D:\,E:\ -OutDir C:\disk-space-analysis-reports -Duplicates -HashDuplicates -AllocatedSize -EventLog
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string[]]$Path,
  [string]$OutDir = '.\disk-space-analysis-reports',
  [int]$TopFiles = 200,
  [int]$TopFolders = 500,
  [int]$Depth = 0,
  [int]$ExportDepth = 6,
  [int]$MaxChildren = 40,
  [switch]$Duplicates,
  [switch]$HashDuplicates,
  [long]$DuplicateMinBytes = 50MB,
  [switch]$AllocatedSize,
  [string[]]$Exclude = @(),
  [ValidateSet('All', 'Json', 'Csv', 'Html')]
  [string]$Format = 'All',
  [switch]$EventLog,
  [switch]$Quiet
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if ($HashDuplicates) { $Duplicates = $true }
if ($TopFiles -lt 1) { $TopFiles = 1 }
if ($TopFolders -lt 1) { $TopFolders = 1 }
if ($ExportDepth -lt 1) { $ExportDepth = 1 }
if ($MaxChildren -lt 1) { $MaxChildren = 1 }
if ($DuplicateMinBytes -lt 256KB) { $DuplicateMinBytes = 256KB }

$script:Denied = 0
$script:Reparse = 0
$script:FilesSeen = 0
$script:Errors = New-Object System.Collections.Generic.List[object]
$script:Ext = @{}
$script:Age = @{}
$script:AgeFiles = @{}
$script:AgeFileMin = @{}
$script:AgeFileCap = 40
$script:ExtFiles = @{}
$script:ExtFileMin = @{}
$script:ExtFileCap = 40
$script:LargeFiles = New-Object System.Collections.Generic.List[object]
$script:TopMin = [int64]-1
$script:Dup = @{}

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
  if (-not $Quiet -or $ErrorLine) { Write-Host $line }
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

function Close-RunLog {
  if ($null -eq $script:LogWriter) { return }
  $script:LogWriter.Dispose()
  $script:LogWriter = $null
}

function Add-ScanError([string]$ItemPath, [string]$Message, [string]$Kind) {
  if ($Kind -eq 'reparse') { $script:Reparse++ } else { $script:Denied++ }
  if ($script:Errors.Count -ge 500) { return }
  [void]$script:Errors.Add([ordered]@{ path = $ItemPath; message = $Message })
}

function Test-Excluded([string]$FullName, [string]$Name) {
  foreach ($pattern in $Exclude) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
    if ($pattern.Contains('*') -or $pattern.Contains('?')) {
      if ($Name -like $pattern -or $FullName -like $pattern) { return $true }
    } else {
      if ($Name -eq $pattern) { return $true }
      if ($FullName -like "*\$pattern") { return $true }
      if ($FullName -like "*\$pattern\*") { return $true }
    }
  }
  return $false
}

function Get-AgeBucket([datetime]$Utc) {
  $days = ([datetime]::UtcNow - $Utc).TotalDays
  if ($days -lt 0) { $days = 0 }
  if ($days -le 7) { return '0-7 days' }
  if ($days -le 30) { return '8-30 days' }
  if ($days -le 90) { return '31-90 days' }
  if ($days -le 365) { return '91-365 days' }
  if ($days -le 1095) { return '1-3 years' }
  return 'Older than 3 years'
}

function Add-Stat([System.Collections.IDictionary]$Table, [string]$Key, [int64]$Count, [int64]$Logical, [int64]$Allocated) {
  if (-not $Table.Contains($Key)) {
    $Table[$Key] = @{
      fileCount = [int64]0
      logicalBytes = [int64]0
      allocatedBytes = [int64]0
    }
  }
  $row = $Table[$Key]
  $row.fileCount = [int64]$row.fileCount + $Count
  $row.logicalBytes = [int64]$row.logicalBytes + $Logical
  $row.allocatedBytes = [int64]$row.allocatedBytes + $Allocated
}

function Update-TopMin {
  if ($script:LargeFiles.Count -eq 0) { $script:TopMin = [int64]-1; return }
  $min = [int64]$script:LargeFiles[0].logicalBytes
  for ($i = 1; $i -lt $script:LargeFiles.Count; $i++) {
    $value = [int64]$script:LargeFiles[$i].logicalBytes
    if ($value -lt $min) { $min = $value }
  }
  $script:TopMin = $min
}

function Add-CappedFile([System.Collections.IDictionary]$Bag, [System.Collections.IDictionary]$Mins, [int]$Cap, [string]$Key, $FileRow) {
  if (-not $Bag.Contains($Key)) {
    $Bag[$Key] = New-Object System.Collections.Generic.List[object]
    $Mins[$Key] = [int64]-1
  }
  $list = $Bag[$Key]
  $size = [int64]$FileRow.logicalBytes
  if ($list.Count -lt $Cap) {
    [void]$list.Add($FileRow)
    if ($list.Count -eq $Cap) {
      $min = [int64]$list[0].logicalBytes
      for ($i = 1; $i -lt $list.Count; $i++) {
        if ([int64]$list[$i].logicalBytes -lt $min) { $min = [int64]$list[$i].logicalBytes }
      }
      $Mins[$Key] = $min
    }
    return
  }
  if ($size -le [int64]$Mins[$Key]) { return }
  $minIdx = 0
  $minVal = [int64]$list[0].logicalBytes
  for ($i = 1; $i -lt $list.Count; $i++) {
    $value = [int64]$list[$i].logicalBytes
    if ($value -lt $minVal) { $minVal = $value; $minIdx = $i }
  }
  $list.RemoveAt($minIdx)
  [void]$list.Add($FileRow)
  $min = [int64]$list[0].logicalBytes
  for ($i = 1; $i -lt $list.Count; $i++) {
    if ([int64]$list[$i].logicalBytes -lt $min) { $min = [int64]$list[$i].logicalBytes }
  }
  $Mins[$Key] = $min
}

function Add-AgeFile([string]$Bucket, $FileRow) {
  Add-CappedFile $script:AgeFiles $script:AgeFileMin $script:AgeFileCap $Bucket $FileRow
}

function Add-ExtFile([string]$Extension, $FileRow) {
  Add-CappedFile $script:ExtFiles $script:ExtFileMin $script:ExtFileCap $Extension $FileRow
}

function Add-LargeFile($FileRow) {
  $size = [int64]$FileRow.logicalBytes
  if ($script:LargeFiles.Count -lt $TopFiles) {
    [void]$script:LargeFiles.Add($FileRow)
    if ($script:LargeFiles.Count -eq $TopFiles) { Update-TopMin }
    return
  }
  if ($size -le $script:TopMin) { return }
  $minIdx = 0
  $minVal = [int64]$script:LargeFiles[0].logicalBytes
  for ($i = 1; $i -lt $script:LargeFiles.Count; $i++) {
    $value = [int64]$script:LargeFiles[$i].logicalBytes
    if ($value -lt $minVal) { $minVal = $value; $minIdx = $i }
  }
  $script:LargeFiles.RemoveAt($minIdx)
  [void]$script:LargeFiles.Add($FileRow)
  Update-TopMin
}

function Get-LongPath([string]$FullName) {
  if ($FullName.StartsWith('\\?\')) { return $FullName }
  if ($FullName.StartsWith('\\')) { return '\\?\UNC\' + $FullName.Substring(2) }
  return '\\?\' + $FullName
}

function Get-ApiPath([string]$FullName) {
  if ($FullName.Length -ge 240) { return Get-LongPath $FullName }
  return $FullName
}

function Get-DisplayPath([string]$FullName) {
  if ($FullName.StartsWith('\\?\UNC\')) { return '\\' + $FullName.Substring(8) }
  if ($FullName.StartsWith('\\?\')) { return $FullName.Substring(4) }
  return $FullName
}

if ($AllocatedSize -and -not ('DiskSpaceNative.Alloc' -as [type])) {
  $native = @'
using System;
using System.Runtime.InteropServices;
namespace DiskSpaceNative {
  public static class Alloc {
    const uint FILE_READ_ATTRIBUTES = 0x80;
    const uint SHARE_ALL = 7;
    const uint OPEN_EXISTING = 3;
    const uint BACKUP = 0x02000000;
    [StructLayout(LayoutKind.Sequential)]
    struct FILE_STANDARD_INFO {
      public long AllocationSize;
      public long EndOfFile;
      public uint NumberOfLinks;
      public byte DeletePending;
      public byte Directory;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr templateFile);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandleEx(IntPtr handle, int cls, out FILE_STANDARD_INFO info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);
    public static long GetAllocation(string path) {
      IntPtr handle = CreateFileW(path, FILE_READ_ATTRIBUTES, SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, BACKUP, IntPtr.Zero);
      if (handle == IntPtr.Zero || handle.ToInt64() == -1) return -1;
      try {
        FILE_STANDARD_INFO info;
        uint bytes = (uint)Marshal.SizeOf(typeof(FILE_STANDARD_INFO));
        if (!GetFileInformationByHandleEx(handle, 1, out info, bytes)) return -1;
        return info.AllocationSize;
      } finally {
        CloseHandle(handle);
      }
    }
  }
}
'@
  Add-Type -TypeDefinition $native
}

function Get-Allocated([string]$FullName, [int64]$Logical) {
  if (-not $AllocatedSize) { return $Logical }
  try {
    $value = [int64][DiskSpaceNative.Alloc]::GetAllocation((Get-ApiPath $FullName))
    if ($value -ge 0) { return $value }
  } catch { }
  return $Logical
}

function New-Folder([string]$Name, [string]$FullName, [int]$NodeDepth) {
  return @{
    Name = $Name
    Path = $FullName
    Depth = $NodeDepth
    DirectLogical = [int64]0
    DirectAllocated = [int64]0
    DirectFiles = [int64]0
    LogicalBytes = [int64]0
    AllocatedBytes = [int64]0
    FileCount = [int64]0
    FolderCount = [int64]0
    Children = New-Object System.Collections.Generic.List[object]
  }
}

function Update-Rollup($Root) {
  $stack = New-Object System.Collections.Generic.Stack[object]
  $stack.Push(@{ Node = $Root; Visited = $false })
  while ($stack.Count -gt 0) {
    $item = $stack.Pop()
    $node = $item.Node
    if (-not $item.Visited) {
      $stack.Push(@{ Node = $node; Visited = $true })
      foreach ($child in $node.Children) {
        $stack.Push(@{ Node = $child; Visited = $false })
      }
    } else {
      $logical = [int64]$node.DirectLogical
      $alloc = [int64]$node.DirectAllocated
      $files = [int64]$node.DirectFiles
      $folders = [int64]0
      foreach ($child in $node.Children) {
        $logical += [int64]$child.LogicalBytes
        $alloc += [int64]$child.AllocatedBytes
        $files += [int64]$child.FileCount
        $folders += 1 + [int64]$child.FolderCount
      }
      $node.LogicalBytes = $logical
      $node.AllocatedBytes = $alloc
      $node.FileCount = $files
      $node.FolderCount = $folders
    }
  }
}

function Add-Depth($Node, [int]$Delta) {
  $Node.Depth = [int]$Node.Depth + $Delta
  foreach ($next in @($Node.Children)) { Add-Depth $next $Delta }
}

function Invoke-ScanRoot($Node, $Info) {
  $stack = New-Object System.Collections.Generic.Stack[object]
  $stack.Push(@{ Node = $Node; Info = $Info })

while ($stack.Count -gt 0) {
  $frame = $stack.Pop()
  $node = $frame.Node
  $info = $frame.Info
  try {
    foreach ($file in $info.EnumerateFiles()) {
      $script:FilesSeen++
      if (($script:FilesSeen % 20000) -eq 0) {
        Write-Note ("{0:n0} files  {1}" -f $script:FilesSeen, $node.Path)
      }
      $display = $file.FullName
      try {
        $display = Get-DisplayPath $file.FullName
        if (Test-Excluded $display $file.Name) { continue }
        $logical = [int64]$file.Length
        $alloc = Get-Allocated $display $logical
        $node.DirectLogical = [int64]$node.DirectLogical + $logical
        $node.DirectAllocated = [int64]$node.DirectAllocated + $alloc
        $node.DirectFiles = [int64]$node.DirectFiles + 1
        $ext = $file.Extension
        if ([string]::IsNullOrEmpty($ext)) { $ext = '(none)' } else { $ext = $ext.ToLowerInvariant() }
        Add-Stat $script:Ext $ext 1 $logical $alloc
        $modified = $file.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $bucket = $null
        try { $bucket = Get-AgeBucket $file.LastWriteTimeUtc } catch { }
        if ($bucket) { Add-Stat $script:Age $bucket 1 $logical $alloc }
        if ($logical -gt 0) {
          $fileRow = [ordered]@{
            path = $display
            name = $file.Name
            extension = $ext
            logicalBytes = $logical
            allocatedBytes = $alloc
            modifiedUtc = $modified
          }
          Add-LargeFile $fileRow
          if ($bucket) { Add-AgeFile $bucket $fileRow }
          Add-ExtFile $ext $fileRow
        }
        if ($Duplicates -and $logical -ge $DuplicateMinBytes) {
          $key = [string]$logical
          if (-not $script:Dup.Contains([string]$key)) {
            $script:Dup[[string]$key] = New-Object System.Collections.Generic.List[string]
          }
          if ($script:Dup[[string]$key].Count -lt 100) { [void]$script:Dup[[string]$key].Add($display) }
        }
      } catch {
        Add-ScanError $display $_.Exception.Message 'error'
      }
    }
  } catch {
    Add-ScanError $node.Path $_.Exception.Message 'error'
  }

  $stop = ($Depth -gt 0 -and ([int]$node.Depth -ge $Depth))
  if ($stop) { continue }
  try {
    foreach ($dir in $info.EnumerateDirectories()) {
      $displayDir = $dir.FullName
      try {
        $displayDir = Get-DisplayPath $dir.FullName
        if (Test-Excluded $displayDir $dir.Name) { continue }
        $attrs = $dir.Attributes
        if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
          Add-ScanError $displayDir 'Reparse point skipped (junction or symlink).' 'reparse'
          continue
        }
        $child = New-Folder $dir.Name $displayDir ([int]$node.Depth + 1)
        [void]$node.Children.Add($child)
        $nextInfo = $dir
        if ($displayDir.Length -ge 240) { $nextInfo = New-Object System.IO.DirectoryInfo (Get-LongPath $displayDir) }
        $stack.Push(@{ Node = $child; Info = $nextInfo })
      } catch {
        Add-ScanError $displayDir $_.Exception.Message 'error'
      }
    }
  } catch {
    Add-ScanError $node.Path $_.Exception.Message 'error'
  }
}

}

$targets = New-Object System.Collections.Generic.List[string]
foreach ($item in @($Path)) {
  foreach ($part in ([string]$item).Split(';')) {
    $piece = $part.Trim()
    if ($piece) { [void]$targets.Add($piece) }
  }
}
Initialize-RunLog
try {
if ($targets.Count -lt 1) {
  Write-Note "Path is required." -ErrorLine -Event
  exit 2
}

$watch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Note ("Started scan. Output {0}" -f $OutDir) -Event
$scanned = New-Object System.Collections.Generic.List[object]
$fullPaths = New-Object System.Collections.Generic.List[string]
foreach ($target in $targets) {
  try {
    $fullRoot = [System.IO.Path]::GetFullPath($target)
  } catch {
    Write-Note "Path is not valid: $target" -ErrorLine -Event
    exit 2
  }
  $probe = New-Object System.IO.DirectoryInfo $fullRoot
  if (-not $probe.Exists) {
    Write-Note "Path not found or not a directory: $fullRoot" -ErrorLine -Event
    exit 2
  }
  $rootName = $fullRoot
  if ($fullRoot.Length -gt 3) { $rootName = $probe.Name }
  $scannedRoot = New-Folder $rootName $fullRoot 0
  Write-Note "Scanning $fullRoot" -Event
  Invoke-ScanRoot $scannedRoot $probe
  [void]$scanned.Add($scannedRoot)
  [void]$fullPaths.Add($fullRoot)
}

if ($scanned.Count -eq 1) {
  $root = $scanned[0]
} else {
  $joined = ($fullPaths -join ' | ')
  $root = New-Folder 'Scanned paths' $joined 0
  foreach ($child in $scanned) {
    Add-Depth $child 1
    [void]$root.Children.Add($child)
  }
}

Write-Note "Rolling up folder sizes..." -Event
Update-Rollup $root
$watch.Stop()

function New-ExportNode($Node, [int]$Level) {
  $kids = New-Object System.Collections.Generic.List[object]
  $sumL = [int64]0
  $sumA = [int64]0
  if ($Level -lt $ExportDepth) {
    $sorted = @($Node.Children | Sort-Object { [int64]$_.LogicalBytes } -Descending)
    $positive = 0
    foreach ($child in $sorted) { if ([int64]$child.LogicalBytes -gt 0) { $positive++ } }
    $kept = 0
    foreach ($child in $sorted) {
      if ([int64]$child.LogicalBytes -le 0) { continue }
      if ($kept -ge $MaxChildren) { break }
      $exported = New-ExportNode $child ($Level + 1)
      [void]$kids.Add($exported)
      $sumL += [int64]$exported.logicalBytes
      $sumA += [int64]$exported.allocatedBytes
      $kept++
    }
    $remL = [int64]$Node.LogicalBytes - $sumL
    if ($kids.Count -gt 0 -and $remL -gt 0) {
      $label = '(other)'
      if ($positive -le $MaxChildren) { $label = '(files here)' }
      [void]$kids.Add([ordered]@{
        name = $label
        path = [string]$Node.Path
        logicalBytes = $remL
        allocatedBytes = [int64]([Math]::Max([int64]0, [int64]$Node.AllocatedBytes - $sumA))
        fileCount = [int64]0
        folderCount = [int64]0
        children = @()
      })
    }
  }
  return [ordered]@{
    name = [string]$Node.Name
    path = [string]$Node.Path
    logicalBytes = [int64]$Node.LogicalBytes
    allocatedBytes = [int64]$Node.AllocatedBytes
    fileCount = [int64]$Node.FileCount
    folderCount = [int64]$Node.FolderCount
    children = $kids
  }
}

function Get-FileHashHex([string]$FilePath) {
  $stream = New-Object System.IO.FileStream((Get-ApiPath $FilePath), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $bytes = $sha.ComputeHash($stream)
      $text = ([System.BitConverter]::ToString([byte[]]$bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
      $sha.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
  return $text
}

function Get-MapValue($Map, [string]$Key) {
  $dict = $Map -as [System.Collections.IDictionary]
  if ($null -eq $dict -or -not $dict.Contains($Key)) { return $null }
  Write-Output -NoEnumerate $dict[$Key]
}

$duplicateRows = New-Object System.Collections.Generic.List[object]
if ($Duplicates) {
  Write-Note "Grouping duplicate candidates..."
  foreach ($key in @($script:Dup.Keys)) {
    $stored = $script:Dup[[string]$key]
    $paths = New-Object System.Collections.Generic.List[string]
    if ($stored -is [System.Collections.IEnumerable] -and $stored -isnot [string]) {
      foreach ($one in $stored) { if ($one) { [void]$paths.Add([string]$one) } }
    } elseif ($stored) {
      [void]$paths.Add([string]$stored)
    }
    if ($paths.Count -lt 2) { continue }
    $size = [int64]$key
    if ($HashDuplicates) {
      $byHash = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]'
      foreach ($filePath in $paths) {
        try {
          $hash = [string](Get-FileHashHex $filePath)
          if ([string]::IsNullOrEmpty($hash)) { continue }
          if ($byHash.ContainsKey($hash)) {
            $group = $byHash[$hash]
          } else {
            $group = New-Object System.Collections.Generic.List[string]
            $byHash.Add($hash, $group)
          }
          [void]$group.Add($filePath)
        } catch {
          Add-ScanError $filePath ("Hash failed: " + $_.Exception.Message) 'error'
        }
      }
      foreach ($pair in $byHash.GetEnumerator()) {
        $group = $pair.Value
        if ($group.Count -lt 2) { continue }
        $waste = $size * ([int64]$group.Count - 1)
        [void]$duplicateRows.Add(@{
          match = 'sha256'
          hash = [string]$pair.Key
          logicalBytes = $size
          count = [int64]$group.Count
          wasteBytes = $waste
          paths = @($group)
        })
      }
    } else {
      $waste = $size * ([int64]$paths.Count - 1)
      [void]$duplicateRows.Add([ordered]@{
        match = 'size'
        logicalBytes = $size
        count = [int64]$paths.Count
        wasteBytes = $waste
        paths = @($paths)
      })
    }
  }
}

$duplicateWaste = [int64]0
foreach ($row in $duplicateRows) { $duplicateWaste += [int64]$row.wasteBytes }

$extRows = New-Object System.Collections.Generic.List[object]
foreach ($key in @($script:Ext.Keys)) {
  $row = $script:Ext[[string]$key]
  $extFiles = @()
  $extStored = Get-MapValue $script:ExtFiles ([string]$key)
  if ($null -ne $extStored) {
    $extFiles = @($extStored | Sort-Object { [int64]$_.logicalBytes } -Descending)
  }
  [void]$extRows.Add([ordered]@{
    extension = [string]$key
    fileCount = [int64]$row.fileCount
    logicalBytes = [int64]$row.logicalBytes
    allocatedBytes = [int64]$row.allocatedBytes
    files = $extFiles
  })
}
$extSorted = @($extRows | Sort-Object { [int64]$_.logicalBytes } -Descending)

$ageOrder = @('0-7 days', '8-30 days', '31-90 days', '91-365 days', '1-3 years', 'Older than 3 years')
$ageRows = New-Object System.Collections.Generic.List[object]
foreach ($bucket in $ageOrder) {
  $ageFiles = @()
  $ageStored = Get-MapValue $script:AgeFiles ([string]$bucket)
  if ($null -ne $ageStored) {
    $ageFiles = @($ageStored | Sort-Object { [int64]$_.logicalBytes } -Descending)
  }
  $ageMap = $script:Age -as [System.Collections.IDictionary]
  if ($null -ne $ageMap -and $ageMap.Contains([string]$bucket)) {
    $row = $ageMap[[string]$bucket]
    [void]$ageRows.Add([ordered]@{
      bucket = $bucket
      fileCount = [int64]$row.fileCount
      logicalBytes = [int64]$row.logicalBytes
      allocatedBytes = [int64]$row.allocatedBytes
      files = $ageFiles
    })
  } else {
    [void]$ageRows.Add([ordered]@{
      bucket = $bucket
      fileCount = [int64]0
      logicalBytes = [int64]0
      allocatedBytes = [int64]0
      files = $ageFiles
    })
  }
}

$folderFlat = New-Object System.Collections.Generic.List[object]
$topFolderRows = New-Object System.Collections.Generic.List[object]
$topFolderMin = [int64]-1
function Consider-Folder($Row) {
  $size = [int64]$Row.logicalBytes
  if ($topFolderRows.Count -lt $TopFolders) {
    [void]$topFolderRows.Add($Row)
    if ($topFolderRows.Count -eq $TopFolders) {
      $min = [int64]$topFolderRows[0].logicalBytes
      foreach ($item in $topFolderRows) { if ([int64]$item.logicalBytes -lt $min) { $min = [int64]$item.logicalBytes } }
      $script:topFolderMinHolder = $min
    }
    return
  }
  if ($size -le [int64]$script:topFolderMinHolder) { return }
  $minIdx = 0
  $minVal = [int64]$topFolderRows[0].logicalBytes
  for ($i = 1; $i -lt $topFolderRows.Count; $i++) {
    if ([int64]$topFolderRows[$i].logicalBytes -lt $minVal) { $minVal = [int64]$topFolderRows[$i].logicalBytes; $minIdx = $i }
  }
  $topFolderRows.RemoveAt($minIdx)
  [void]$topFolderRows.Add($Row)
  $min = [int64]$topFolderRows[0].logicalBytes
  foreach ($item in $topFolderRows) { if ([int64]$item.logicalBytes -lt $min) { $min = [int64]$item.logicalBytes } }
  $script:topFolderMinHolder = $min
}
$script:topFolderMinHolder = [int64]-1

$walk = New-Object System.Collections.Generic.Stack[object]
$walk.Push($root)
while ($walk.Count -gt 0) {
  $current = $walk.Pop()
  $row = [ordered]@{
    path = [string]$current.Path
    name = [string]$current.Name
    logicalBytes = [int64]$current.LogicalBytes
    allocatedBytes = [int64]$current.AllocatedBytes
    fileCount = [int64]$current.FileCount
    folderCount = [int64]$current.FolderCount
    depth = [int]$current.Depth
  }
  [void]$folderFlat.Add($row)
  if ([int]$current.Depth -gt 0) { Consider-Folder $row }
  foreach ($child in $current.Children) { $walk.Push($child) }
}

$filesSorted = @($script:LargeFiles | Sort-Object { [int64]$_.logicalBytes } -Descending)
$foldersSorted = @($topFolderRows | Sort-Object { [int64]$_.logicalBytes } -Descending)
$dupSorted = @($duplicateRows | Sort-Object { [int64]$_.wasteBytes } -Descending)

Write-Note "Building JSON tree..."
if ($scanned.Count -gt 1) { $ExportDepth = $ExportDepth + 1 }
$tree = New-ExportNode $root 0

$report = [ordered]@{
  kind = 'scan'
  tool = 'disk-space-analysis.powershell'
  version = '1.0'
  scannedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  host = [string]$env:COMPUTERNAME
  root = [string]$root.Path
  roots = @($fullPaths)
  elapsedMs = [int64]$watch.ElapsedMilliseconds
  summary = [ordered]@{
    logicalBytes = [int64]$root.LogicalBytes
    allocatedBytes = [int64]$root.AllocatedBytes
    fileCount = [int64]$root.FileCount
    folderCount = [int64]$root.FolderCount
    deniedCount = [int64]$script:Denied
    reparseSkipped = [int64]$script:Reparse
    duplicateGroups = [int64]$dupSorted.Count
    duplicateWasteBytes = $duplicateWaste
    allocatedCollected = [bool]$AllocatedSize
  }
  tree = $tree
  largestFolders = $foldersSorted
  largestFiles = $filesSorted
  extensions = $extSorted
  ages = $ageRows
  duplicates = $dupSorted
  errors = $script:Errors
}

function Append-JsonString([System.Text.StringBuilder]$Sb, [string]$Text) {
  [void]$Sb.Append('"')
  foreach ($ch in $Text.ToCharArray()) {
    $code = [int]$ch
    if ($code -eq 34) { [void]$Sb.Append('\"'); continue }
    if ($code -eq 92) { [void]$Sb.Append('\\'); continue }
    if ($code -eq 10) { [void]$Sb.Append('\n'); continue }
    if ($code -eq 13) { [void]$Sb.Append('\r'); continue }
    if ($code -eq 9) { [void]$Sb.Append('\t'); continue }
    if ($code -lt 32) { [void]$Sb.Append('\u'); [void]$Sb.Append($code.ToString('x4')); continue }
    [void]$Sb.Append($ch)
  }
  [void]$Sb.Append('"')
}

function Test-JsonNumber($Value) {
  return $Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single] -or $Value -is [uint32] -or $Value -is [uint64]
}

function Append-Json([System.Text.StringBuilder]$Sb, $Value) {
  if ($null -eq $Value) { [void]$Sb.Append('null'); return }
  if ($Value -is [string]) { Append-JsonString $Sb $Value; return }
  if ($Value -is [bool]) {
    if ($Value) { [void]$Sb.Append('true') } else { [void]$Sb.Append('false') }
    return
  }
  if (Test-JsonNumber $Value) {
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

function Write-JsonFile([string]$Target, $Value) {
  $sb = New-Object System.Text.StringBuilder
  Append-Json $sb $Value
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Target, $sb.ToString(), $utf8)
}

function ConvertTo-CsvCell($Value) {
  if ($null -eq $Value) { return '' }
  $text = [string]$Value
  if ($text.IndexOfAny(@([char]34, [char]44, [char]10, [char]13)) -ge 0) {
    return '"' + $text.Replace('"', '""') + '"'
  }
  return $text
}

function Write-CsvFile([string]$Target, [string[]]$Headers, $Rows) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine(($Headers -join ','))
  foreach ($row in $Rows) {
    $cells = New-Object System.Collections.Generic.List[string]
    foreach ($header in $Headers) {
      $cell = $null
      if ($row -is [System.Collections.IDictionary]) { $cell = $row[$header] }
      else { $cell = $row.$header }
      [void]$cells.Add((ConvertTo-CsvCell $cell))
    }
    [void]$sb.AppendLine(($cells -join ','))
  }
  $utf8 = New-Object System.Text.UTF8Encoding $true
  [System.IO.File]::WriteAllText($Target, $sb.ToString(), $utf8)
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

function Escape-Html([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $amp = '&' + 'amp;'
  $lt = '&' + 'lt;'
  $gt = '&' + 'gt;'
  return $Text.Replace('&', $amp).Replace('<', $lt).Replace('>', $gt)
}

function Write-HtmlFile([string]$Target, [string]$Json) {
  $templatePath = Join-Path $PSScriptRoot 'viewer.html'
  $safe = $Json.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
  $embed = '<script id="disk-space-analysis-embed" type="application/json">' + $safe + '</script>'
  if (Test-Path -LiteralPath $templatePath) {
    $template = [System.IO.File]::ReadAllText($templatePath)
    if ($template.Contains('<!--DISK_SPACE_ANALYSIS_EMBED-->')) {
      $html = $template.Replace('<!--DISK_SPACE_ANALYSIS_EMBED-->', $embed)
    } else {
      $html = $template
    }
  } else {
    $html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>disk-space-analysis</title></head><body><p>viewer.html was not next to the script.</p>' + $embed + '</body></html>'
  }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Target, $html, $utf8)
}

[void][System.IO.Directory]::CreateDirectory($OutDir)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonBuilder = New-Object System.Text.StringBuilder
Append-Json $jsonBuilder $report
$jsonText = $jsonBuilder.ToString()
$writeJson = $Format -eq 'All' -or $Format -eq 'Json'
$writeCsv = $Format -eq 'All' -or $Format -eq 'Csv'
$writeHtml = $Format -eq 'All' -or $Format -eq 'Html'

if ($writeJson) {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText((Join-Path $OutDir 'latest.json'), $jsonText, $utf8)
  [System.IO.File]::WriteAllText((Join-Path $OutDir ("disk-space-analysis-$stamp.json")), $jsonText, $utf8)
}
if ($writeCsv) {
  $folderHeaders = @('path', 'name', 'logicalBytes', 'allocatedBytes', 'fileCount', 'folderCount', 'depth')
  $fileHeaders = @('path', 'name', 'extension', 'logicalBytes', 'allocatedBytes', 'modifiedUtc')
  $extHeaders = @('extension', 'fileCount', 'logicalBytes', 'allocatedBytes')
  $extFileHeaders = @('extension', 'path', 'name', 'logicalBytes', 'allocatedBytes', 'modifiedUtc')
  $extFileRows = New-Object System.Collections.Generic.List[object]
  foreach ($row in $extSorted) {
    foreach ($file in @($row.files)) {
      [void]$extFileRows.Add([ordered]@{
        extension = [string]$row.extension
        path = [string]$file.path
        name = [string]$file.name
        logicalBytes = [int64]$file.logicalBytes
        allocatedBytes = [int64]$file.allocatedBytes
        modifiedUtc = [string]$file.modifiedUtc
      })
    }
  }
  $ageHeaders = @('bucket', 'fileCount', 'logicalBytes', 'allocatedBytes')
  $ageFileHeaders = @('bucket', 'path', 'name', 'extension', 'logicalBytes', 'allocatedBytes', 'modifiedUtc')
  $ageFileRows = New-Object System.Collections.Generic.List[object]
  foreach ($row in $ageRows) {
    foreach ($file in @($row.files)) {
      [void]$ageFileRows.Add([ordered]@{
        bucket = [string]$row.bucket
        path = [string]$file.path
        name = [string]$file.name
        extension = [string]$file.extension
        logicalBytes = [int64]$file.logicalBytes
        allocatedBytes = [int64]$file.allocatedBytes
        modifiedUtc = [string]$file.modifiedUtc
      })
    }
  }
  $dupHeaders = @('match', 'hash', 'logicalBytes', 'count', 'wasteBytes', 'paths')
  $errHeaders = @('path', 'message')
  $dupCsv = New-Object System.Collections.Generic.List[object]
  foreach ($row in $dupSorted) {
    $hash = ''
    if ($row.Contains('hash')) { $hash = [string]$row.hash }
    [void]$dupCsv.Add([ordered]@{
      match = [string]$row.match
      hash = $hash
      logicalBytes = [int64]$row.logicalBytes
      count = [int64]$row.count
      wasteBytes = [int64]$row.wasteBytes
      paths = ((@($row.paths)) -join '|')
    })
  }
  Write-CsvFile (Join-Path $OutDir 'latest-folders.csv') $folderHeaders $folderFlat
  Write-CsvFile (Join-Path $OutDir 'latest-files.csv') $fileHeaders $filesSorted
  Write-CsvFile (Join-Path $OutDir 'latest-extensions.csv') $extHeaders $extSorted
  Write-CsvFile (Join-Path $OutDir 'latest-extension-files.csv') $extFileHeaders $extFileRows
  Write-CsvFile (Join-Path $OutDir 'latest-ages.csv') $ageHeaders $ageRows
  Write-CsvFile (Join-Path $OutDir 'latest-age-files.csv') $ageFileHeaders $ageFileRows
  Write-CsvFile (Join-Path $OutDir 'latest-duplicates.csv') $dupHeaders $dupCsv
  Write-CsvFile (Join-Path $OutDir 'latest-errors.csv') $errHeaders $script:Errors
  Write-CsvFile (Join-Path $OutDir ("disk-space-analysis-$stamp-folders.csv")) $folderHeaders $folderFlat
}
if ($writeHtml) {
  Write-HtmlFile (Join-Path $OutDir 'latest.html') $jsonText
  Write-HtmlFile (Join-Path $OutDir ("disk-space-analysis-$stamp.html")) $jsonText
}

Write-Note ("Done in {0:n1}s. Logical {1}. Files {2:n0}. Denied {3}. Reports in {4}. Log {5}" -f $watch.Elapsed.TotalSeconds, (Format-Byte ([int64]$root.LogicalBytes)), [int64]$root.FileCount, $script:Denied, (Resolve-Path $OutDir), (Join-Path $OutDir 'disk-space-analysis.log')) -Event
if ($Depth -gt 0) { Write-Note "Depth limit $Depth was set. Totals exclude anything deeper." -Event }
} finally {
  Close-RunLog
}
exit 0
