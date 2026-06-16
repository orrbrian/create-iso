# Create ISO from Folder

A small Windows utility that adds a **"Create ISO from folder"** right-click
menu entry to File Explorer. Point it at any folder and it produces an ISO
image of that folder's contents, using only components built into Windows —
no third-party tools, no admin rights.

## What it does

- Adds a context-menu entry to folders (and to the empty background inside
  an opened folder) that runs a PowerShell script.
- Builds the ISO via the built-in `IMAPI2FS` COM component.
- Shows a WinForms progress dialog with transfer rate, ETA, and a working
  **Cancel** button.
- Automatically switches to **UDF 2.50** when the source contains any file
  larger than 4 GiB (the hard limit for ISO9660/Joliet), so large video,
  disk-image, and archive files Just Work.
- After a successful write, computes a **SHA1** of the ISO (also on a
  responsive, cancelable progress bar), copies the hex digest to the
  clipboard, and writes a verbose `.sha1.txt` sidecar next to the ISO.

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (ships with Windows)

No external dependencies. No admin rights needed — everything installs under
`HKCU` and `%LOCALAPPDATA%`.

## Install

Clone or download the repo, then double-click `install.bat` (or run it from
a cmd prompt). It will:

1. Copy `New-IsoFromFolder.ps1` and `Launch-Hidden.vbs` to
   `%LOCALAPPDATA%\CreateIso\`.
2. Register two context-menu entries under `HKCU\Software\Classes\Directory`:
   - **Create ISO from folder** — when you right-click a folder.
   - **Create ISO from this folder** — when you right-click the empty
     background inside an opened folder.

The context-menu command invokes `wscript.exe Launch-Hidden.vbs "<folder>"`,
which in turn launches the PowerShell script with no visible console window
— only the WinForms progress dialog is shown.

On Windows 11 the entry lives under **"Show more options"** (or press
`Shift+F10` instead of a normal right-click to get the classic menu directly).

## Uninstall

Double-click `uninstall.bat`. It removes the registry entries and deletes
`%LOCALAPPDATA%\CreateIso\`.

## Usage

Right-click a folder -> **Create ISO from folder**. The progress dialog
appears and walks through four phases:

1. **Scanning** the source folder (and checking for oversized files).
2. **Building** the file system image in memory via IMAPI.
3. **Writing ISO** to disk, with live MiB/s and ETA.
4. **Computing SHA1** of the finished image, with live MiB/s and ETA.

On success:

- `<folder>.iso` is written next to the source folder.
- `<folder>.iso.sha1.txt` is written next to it with verbose hash info.
- The lowercase SHA1 hex digest is placed on the clipboard, ready to paste.

Cancel at any time with the **Cancel** button or by closing the dialog.
Partial ISO files are deleted on cancel or error.

### Running the script directly

You don't have to use the context menu. The script is a normal PowerShell
script and can be invoked from a terminal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Sta `
  -File .\New-IsoFromFolder.ps1 `
  "D:\path\to\source folder" `
  "D:\path\to\output.iso" `
  "MY_VOLUME_LABEL"
```

Parameters:

| # | Name         | Required | Default                                 |
|---|--------------|----------|-----------------------------------------|
| 1 | `FolderPath` | yes      | -                                       |
| 2 | `OutputPath` | no       | `<FolderPath>.iso` next to the source   |
| 3 | `VolumeName` | no       | folder name, sanitized and uppercased   |

The `-Sta` flag is required because the script uses WinForms for the
progress dialog.

## The `.sha1.txt` sidecar

After a successful run the script writes a file like
`saved videos.iso.sha1.txt` containing:

```
File:        saved videos.iso
Path:        D:\yt-dl\saved videos.iso
Size:        12,345,678,901 bytes  (11.50 GiB / 11,773.44 MiB)
SHA1:        0123456789abcdef0123456789abcdef01234567
Created:     2026-04-11 15:42:17 -05:00
Source:      D:\yt-dl\saved videos
Volume:      SAVED_VIDEOS
Filesystem:  UDF 2.50 (large-file mode)

# sha1sum -c compatible:
0123456789abcdef0123456789abcdef01234567 *saved videos.iso
```

The last line is a `sha1sum -c` compatible entry, so you can verify the
image on any system with GNU coreutils:

```bash
sha1sum -c "saved videos.iso.sha1.txt"
```

The file is written as **UTF-8 without BOM** so POSIX tools don't choke.

## Filesystem selection

The script picks between two filesystem modes based on the contents of the
source folder:

| Condition                          | FileSystemsToCreate     | UDF revision |
|------------------------------------|-------------------------|--------------|
| All files < 4 GiB                  | ISO9660 + Joliet + UDF  | 1.02         |
| Any file >= 4 GiB                  | UDF only                | 2.50         |

**Why:** ISO9660 and Joliet cap individual files at 4 GiB - 1 byte. UDF 1.02
has its own quirks with large files in some implementations. UDF 2.50 is
what Windows itself writes for large image media (dual-layer DVDs, BD), so
it's the most broadly compatible option when large files are present.

A UDF-only image mounts on Windows 7+, macOS, and modern Linux without any
issue. It will not mount on very old systems (pre-WinXP, ancient Linux
kernels), which is a deliberate trade-off for supporting files > 4 GiB.

## How it works (internals)

### Hiding the console flash

`powershell.exe` is a console-subsystem process, so even
`-WindowStyle Hidden` produces a brief black-box flash when launched
directly. To avoid that, the context-menu command runs
`wscript.exe Launch-Hidden.vbs` instead. `wscript.exe` is GUI-subsystem,
and the VBScript calls `Shell.Run(cmd, 0, False)` — `0` = `SW_HIDE` — so
the PowerShell console is created already-hidden and never draws on screen.
The only window the user ever sees is the WinForms progress dialog.

#### The STARTUPINFO gotcha

Using `Shell.Run(cmd, 0)` sets `STARTUPINFO.wShowWindow = SW_HIDE` on
the PowerShell child. Per the Win32 docs, the **first** `ShowWindow`
call in a new GUI process has its `nCmdShow` argument silently replaced
by the `STARTUPINFO` value. WinForms' `Form.Show()` internally calls
`ShowWindow(hwnd, SW_SHOW)` — and that first call gets rewritten to
`SW_HIDE`, so the progress dialog is created but never drawn. The
script runs to completion invisibly, which is surprising and confusing.

The fix, applied in `CreateIso.Progress.Show()`, is to P/Invoke
`ShowWindow(_form.Handle, SW_SHOW)` **a second time** right after
`Form.Show()`. The first call absorbs the `STARTUPINFO` override; the
second one behaves normally and actually makes the form visible. It
is a harmless no-op when the script is launched any other way (e.g.
directly from a PowerShell prompt).

> VBScript is on Microsoft's deprecation list as a future on-demand
> feature. When that bites, the launcher can be replaced with a tiny
> GUI-subsystem `.exe` (e.g. a 10-line C# or Go program) using
> `CREATE_NO_WINDOW`, which sidesteps the `STARTUPINFO` issue entirely
> and would let the double-`ShowWindow` workaround be removed.

### The PowerShell script

The script is a single `.ps1` file. It hosts a small inline C# class,
`CreateIso.Progress`, compiled at first run via `Add-Type`, that provides:

- A WinForms progress dialog with a label, detail line, progress bar, and
  cancel button.
- A `SaveStream` method that pulls the IMAPI result `IStream` into a file
  in 1 MiB chunks, updating the UI and checking for cancel every ~100 ms.
- A `HashFileSha1` method that runs a streaming SHA1 over the finished ISO
  in 1 MiB chunks, again pumping window messages between chunks so the
  dialog stays responsive.

Both long-running operations use cooperative `Application.DoEvents()`
pumping rather than a separate thread — simpler than marshaling between a
worker thread and the UI thread, and plenty smooth for MiB-sized chunks.

## File encoding note

`New-IsoFromFolder.ps1` is saved as **UTF-8 with BOM** and uses only ASCII
characters in its source. PowerShell 5.1 reads BOM-less `.ps1` files as
Windows-1252, which mangles any non-ASCII characters (em-dashes, etc.) in
displayed strings. If you edit the script, keep it ASCII-clean or preserve
the BOM to avoid that class of bug.

## License

MIT. Do whatever you want with it.
