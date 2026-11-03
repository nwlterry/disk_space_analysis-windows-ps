# Disk space analysis for Windows (PowerShell)

Scan one or more folders, volumes, or UNC paths on Windows Server 2016 and later with Windows PowerShell 5.1. No install.

Same job as Tree Size: folder tree, largest files, file types, age, duplicates, and what changed between two scans.

| Path | What it is |
|---|---|
| `src/Get-DiskAnalysis.ps1` | Scanner |
| `src/Compare-DiskAnalysis.ps1` | Compare two `folders.csv` snapshots |
| `src/viewer.html` | Offline screen. Keep it next to the scanner. |

`latest.json` opens in the SizeTree viewer. `latest.html` is that same tabbed screen with the scan embedded, so it opens from disk with no network. `viewer.html` must sit beside `Get-DiskAnalysis.ps1` for that HTML to be written.

Each age group includes up to 40 of the largest files in that age. Click the age to list them. The full list of those files is also `latest-age-files.csv`.

Each file type keeps up to 40 of its largest files. Click the type to list them. Those rows are also `latest-extension-files.csv`.

## Scan

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\src\Get-DiskAnalysis.ps1 -Path D:\,E:\ -OutDir C:\SizeTreeReports -Duplicates -HashDuplicates -AllocatedSize
```

One path still works: `-Path D:\`. Several paths can be comma-separated or split with a semicolon. They are drawn as one map, with a button for each path.

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
| `latest.html` | Same tabbed screen, offline. The scan is embedded. |
| `latest-folders.csv` | Every folder. This is what compare uses. |
| `latest-files.csv` | Largest files on the volume. |
| `latest-extensions.csv` | Space by extension. |
| `latest-ages.csv` | Space by last-write age. |
| `latest-age-files.csv` | Largest files in each age (up to 40 per bucket). |
| `latest-duplicates.csv` | Same-size or SHA-256 groups. |
| `latest-errors.csv` | Access denied and skipped junctions. |

Junctions and symlinks are not followed. Duplicate tracking ignores files under 256 KB and, by default, under 50 MB. A size match is not proof the bytes match. Add `-HashDuplicates` for SHA-256.

Exclude a name or wildcard:

```powershell
.\src\Get-DiskAnalysis.ps1 -Path D:\Shares -Exclude node_modules,*.tmp
```
