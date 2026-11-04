# Disk space analysis for Windows (PowerShell)

Scan one or more folders, volumes, or UNC paths on Windows Server 2016 and later with Windows PowerShell 5.1. No install.

Same job as Tree Size: folder tree, largest files, file types, age, duplicates, and what changed between two scans.

| Path | What it is |
|---|---|
| `src/Get-DiskAnalysis.ps1` | Scanner |
| `src/Compare-DiskAnalysis.ps1` | Compare two `folders.csv` snapshots |
| `src/viewer.html` | Offline screen. Keep it next to the scanner. |

`latest-disk-space-analysis.json` opens in the disk-space-analysis viewer. `latest-disk-space-analysis.html` is that same tabbed screen with the scan embedded, so it opens from disk with no network. `viewer.html` must sit beside `Get-DiskAnalysis.ps1` for that HTML to be written.

Each age group includes up to 40 of the largest files in that age. Click the age to list them. The full list of those files is also `latest-disk-space-analysis-age-files.csv`.

Each file type keeps up to 40 of its largest files. Click the type to list them. Those rows are also `latest-extension-files.csv`.

## Scan

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\src\Get-DiskAnalysis.ps1 -Path D:\,E:\ -OutDir C:\disk-space-analysis-reports -Duplicates -HashDuplicates -AllocatedSize
```

One path still works: `-Path D:\`. Several paths can be comma-separated or split with a semicolon. They are drawn as one map, with a button for each path.

`-AllocatedSize` reads real NTFS allocation, including compressed and sparse files. It is slower because every file is opened for attributes.

`-Depth 3` stops after three levels. Totals then exclude anything deeper. Leave it off for a full volume.

## Compare

Use the folders CSV. It lists every folder, not only the JSON tree.

```powershell
.\src\Compare-DiskAnalysis.ps1 -Before C:\disk-space-analysis-reports\disk-space-analysis-20261006-020000-folders.csv -After C:\disk-space-analysis-reports\disk-space-analysis-20261103-090000-folders.csv -OutDir C:\disk-space-analysis-reports\compare
```

## Reports

| File | What it is |
|---|---|
| `latest-disk-space-analysis.json` | Viewer report. Tree depth is capped (`-ExportDepth`, default 6). Totals still include everything scanned. Age groups include their largest files. |
| `latest-disk-space-analysis.html` | Same tabbed screen, offline. The scan is embedded. |
| `latest-disk-space-analysis-folders.csv` | Every folder. Compare uses `disk-space-analysis-yyyyMMdd-HHmmss-folders.csv`. |
| `latest-disk-space-analysis-files.csv` | Largest files on the volume. Also written with the same timestamp. |
| `latest-disk-space-analysis-extensions.csv` | Space by extension. Also written with the same timestamp. |
| `latest-disk-space-analysis-ages.csv` | Space by last-write age. Also written with the same timestamp. |
| `latest-disk-space-analysis-age-files.csv` | Largest files in each age (up to 40 per bucket). Also written with the same timestamp. |
| `latest-disk-space-analysis-duplicates.csv` | Same-size or SHA-256 groups. Also written with the same timestamp. |
| `latest-disk-space-analysis-errors.csv` | Access denied and skipped junctions. Also written with the same timestamp. |

Junctions and symlinks are not followed. Duplicate tracking ignores files under 256 KB and, by default, under 50 MB. A size match is not proof the bytes match. Add `-HashDuplicates` for SHA-256.

Exclude a name or wildcard:

```powershell
.\src\Get-DiskAnalysis.ps1 -Path D:\Shares -Exclude node_modules,*.tmp
```

## Log

Each run prints `yyyy-MM-dd HH:mm:ss` on every console line and appends the same lines to `disk-space-analysis.log` in the report folder.

PowerShell: `-EventLog`. .NET: `--event-log`. That also writes the start, errors, and the summary to the Windows Application log. The source name is `disk-space-analysis`. The first use must run elevated so Windows can register the source. `-Quiet` / `--quiet` hides console progress. The log file is still written. The periodic file-count lines stay in the console and the log file, not the event log.
