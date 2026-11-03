# Disk space analysis for Windows (PowerShell)

Scan a folder, a volume, or a UNC path on Windows Server 2016 and later with Windows PowerShell 5.1. No install.

Same job as Tree Size: folder tree, largest files, file types, age, duplicates, and what changed between two scans.

| Path | What it is |
|---|---|
| `src/Get-DiskAnalysis.ps1` | Scanner |
| `src/Compare-DiskAnalysis.ps1` | Compare two `folders.csv` snapshots |

`latest.json` opens in the SizeTree viewer. Each age group includes up to 40 of the largest files in that age. Click the age in the viewer to list them. The full list of those files is also `latest-age-files.csv`.

## Scan

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\src\Get-DiskAnalysis.ps1 -Path D:\ -OutDir C:\SizeTreeReports -Duplicates -HashDuplicates -AllocatedSize
```

`-AllocatedSize` reads real NTFS allocation, including compressed and sparse files. It is slower because every file is opened for attributes.

`-Depth 3` stops after three levels. Totals then exclude anything deeper. Leave it off for a full volume.

## Compare

Use the folders CSV. It lists every folder, not only the JSON tree.

```powershell
.\src\Compare-DiskAnalysis.ps1 -Before C:\SizeTreeReports\sizetree-20261006-020000-folders.csv -After C:\SizeTreeReports\latest-folders.csv -OutDir C:\SizeTreeReports\compare
```

## Reports

| File | What it is |
|---|---|
| `latest.json` | Viewer report. Tree depth is capped (`-ExportDepth`, default 6). Totals still include everything scanned. Age groups include their largest files. |
| `latest-folders.csv` | Every folder. This is what compare uses. |
| `latest-files.csv` | Largest files on the volume. |
| `latest-extensions.csv` | Space by extension. |
| `latest-ages.csv` | Space by last-write age. |
| `latest-age-files.csv` | Largest files in each age (up to 40 per bucket). |
| `latest-duplicates.csv` | Same-size or SHA-256 groups. |
| `latest-errors.csv` | Access denied and skipped junctions. |
| `latest.html` | Printable summary, including files by age. |

Junctions and symlinks are not followed. Duplicate tracking ignores files under 256 KB and, by default, under 50 MB. A size match is not proof the bytes match. Add `-HashDuplicates` for SHA-256.

```powershell
.\src\Get-DiskAnalysis.ps1 -Path D:\Shares -Exclude node_modules,*.tmp
```

The .NET scanner that writes the same reports is [disk_space_analysis-windows-dotnet](https://github.com/nwlterry/disk_space_analysis-windows-dotnet).
