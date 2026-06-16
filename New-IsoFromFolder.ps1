#Requires -Version 5.1
<#
.SYNOPSIS
    Creates an ISO file from the contents of a folder using the built-in
    Windows IMAPI2FS COM component. Shows a WinForms progress dialog and
    supports cancellation. No external tools required.

.PARAMETER FolderPath
    The folder whose contents will be placed at the root of the ISO.

.PARAMETER OutputPath
    Optional. Destination .iso path. Defaults to "<FolderPath>.iso" next
    to the source folder.

.PARAMETER VolumeName
    Optional. ISO volume label. Defaults to the folder name.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$FolderPath,

    [Parameter(Position = 1)]
    [string]$OutputPath,

    [Parameter(Position = 2)]
    [string]$VolumeName
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Inline C#: WinForms progress dialog + IStream copy loop --------------
if (-not ('CreateIso.Progress' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Windows.Forms;

namespace CreateIso {
    public static class Progress {
        private static Form _form;
        private static Label _label;
        private static Label _detail;
        private static ProgressBar _bar;
        private static Button _cancel;
        private static bool _canceled;

        // When launched via wscript.exe with Shell.Run(cmd, 0), the child
        // powershell.exe inherits STARTUPINFO.wShowWindow = SW_HIDE. Per
        // MSDN, the *first* ShowWindow call in a GUI process has its
        // nCmdShow argument ignored and replaced with the STARTUPINFO
        // value -- so Form.Show()'s internal ShowWindow(hwnd, SW_SHOW)
        // is silently rewritten to SW_HIDE and the dialog never appears.
        // A second, explicit ShowWindow call uses nCmdShow normally and
        // actually makes the form visible.
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        private const int SW_SHOW = 5;

        public static void Show(string title) {
            _canceled = false;
            _form = new Form {
                Text = title,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                StartPosition = FormStartPosition.CenterScreen,
                MaximizeBox = false,
                MinimizeBox = false,
                ClientSize = new Size(460, 130),
                TopMost = true,
                ShowInTaskbar = true
            };
            _label = new Label {
                Location = new Point(12, 12),
                Size = new Size(436, 20),
                Text = "Preparing..."
            };
            _detail = new Label {
                Location = new Point(12, 34),
                Size = new Size(436, 20),
                ForeColor = Color.DimGray,
                Text = ""
            };
            _bar = new ProgressBar {
                Location = new Point(12, 58),
                Size = new Size(436, 22),
                Style = ProgressBarStyle.Marquee,
                MarqueeAnimationSpeed = 30,
                Minimum = 0,
                Maximum = 1000
            };
            _cancel = new Button {
                Text = "Cancel",
                Location = new Point(366, 92),
                Size = new Size(82, 26)
            };
            _cancel.Click += delegate(object s, EventArgs e) {
                _canceled = true;
                _cancel.Enabled = false;
                _label.Text = "Canceling...";
                Application.DoEvents();
            };
            _form.FormClosing += delegate(object s, FormClosingEventArgs e) {
                if (!_canceled && _form.Visible) {
                    _canceled = true;
                }
            };
            _form.Controls.Add(_label);
            _form.Controls.Add(_detail);
            _form.Controls.Add(_bar);
            _form.Controls.Add(_cancel);
            _form.Show();
            // See the ShowWindow comment at the top of this class: the
            // first ShowWindow in this process gets STARTUPINFO.wShowWindow
            // forced onto it, so an explicit second call is required when
            // launched via wscript Shell.Run(..., 0).
            ShowWindow(_form.Handle, SW_SHOW);
            _form.BringToFront();
            _form.Activate();
            Application.DoEvents();
        }

        public static void SetStatus(string text) {
            if (_form == null) return;
            _label.Text = text;
            _detail.Text = "";
            _bar.Style = ProgressBarStyle.Marquee;
            Application.DoEvents();
        }

        public static void Close() {
            if (_form == null) return;
            try { _form.Hide(); _form.Dispose(); } catch { }
            _form = null;
            Application.DoEvents();
        }

        public static bool WasCanceled() { return _canceled; }

        // Stream the IMAPI result IStream to a file, updating the dialog.
        public static long SaveStream(object comStream, string path, long totalBytes) {
            IStream src = (IStream)comStream;
            try { src.Seek(0, 0, IntPtr.Zero); } catch { }

            if (_form != null) {
                _label.Text = "Writing ISO...";
                _bar.Style = ProgressBarStyle.Continuous;
                _bar.Value = 0;
                Application.DoEvents();
            }

            const int BUF = 1024 * 1024; // 1 MiB
            byte[] buffer = new byte[BUF];
            IntPtr pRead = Marshal.AllocHGlobal(sizeof(int));
            long total = 0;
            DateTime lastUpdate = DateTime.MinValue;
            DateTime start = DateTime.UtcNow;

            try {
                using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None)) {
                    while (true) {
                        if (_canceled) {
                            throw new OperationCanceledException("Canceled by user.");
                        }
                        Marshal.WriteInt32(pRead, 0);
                        src.Read(buffer, BUF, pRead);
                        int read = Marshal.ReadInt32(pRead);
                        if (read <= 0) break;
                        fs.Write(buffer, 0, read);
                        total += read;

                        DateTime now = DateTime.UtcNow;
                        if ((now - lastUpdate).TotalMilliseconds >= 100) {
                            lastUpdate = now;
                            if (_form != null && totalBytes > 0) {
                                long permille = (total * 1000L) / totalBytes;
                                if (permille > 1000) permille = 1000;
                                _bar.Value = (int)permille;

                                double mib = total / 1048576.0;
                                double totMib = totalBytes / 1048576.0;
                                double secs = (now - start).TotalSeconds;
                                double rate = secs > 0 ? mib / secs : 0;
                                double remain = rate > 0 ? (totMib - mib) / rate : 0;
                                string unit = "MiB";
                                double shownNow = mib, shownTot = totMib;
                                if (totMib >= 1024) {
                                    unit = "GiB";
                                    shownNow = mib / 1024.0;
                                    shownTot = totMib / 1024.0;
                                }
                                _label.Text = string.Format(
                                    "Writing ISO... {0:N2} / {1:N2} {2}  ({3:N1}%)",
                                    shownNow, shownTot, unit, permille / 10.0);
                                _detail.Text = string.Format(
                                    "{0:N1} MiB/s   ~{1} remaining",
                                    rate, FormatEta(remain));
                                Application.DoEvents();
                            }
                        }
                    }
                }
            } finally {
                Marshal.FreeHGlobal(pRead);
            }
            return total;
        }

        // Hash a file with SHA1 in 1 MiB chunks, pumping window messages
        // between chunks so the dialog stays responsive and Cancel works.
        public static string HashFileSha1(string path) {
            long totalBytes = new FileInfo(path).Length;

            if (_form != null) {
                _label.Text = "Computing SHA1...";
                _detail.Text = "";
                _bar.Style = ProgressBarStyle.Continuous;
                _bar.Value = 0;
                Application.DoEvents();
            }

            const int BUF = 1024 * 1024; // 1 MiB
            byte[] buffer = new byte[BUF];
            long total = 0;
            DateTime lastUpdate = DateTime.MinValue;
            DateTime start = DateTime.UtcNow;

            using (System.Security.Cryptography.SHA1 sha = System.Security.Cryptography.SHA1.Create())
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                while (true) {
                    if (_canceled) {
                        throw new OperationCanceledException("Canceled by user.");
                    }
                    int read = fs.Read(buffer, 0, BUF);
                    if (read <= 0) {
                        sha.TransformFinalBlock(buffer, 0, 0);
                        break;
                    }
                    sha.TransformBlock(buffer, 0, read, null, 0);
                    total += read;

                    DateTime now = DateTime.UtcNow;
                    if ((now - lastUpdate).TotalMilliseconds >= 100) {
                        lastUpdate = now;
                        if (_form != null && totalBytes > 0) {
                            long permille = (total * 1000L) / totalBytes;
                            if (permille > 1000) permille = 1000;
                            _bar.Value = (int)permille;

                            double mib = total / 1048576.0;
                            double totMib = totalBytes / 1048576.0;
                            double secs = (now - start).TotalSeconds;
                            double rate = secs > 0 ? mib / secs : 0;
                            double remain = rate > 0 ? (totMib - mib) / rate : 0;
                            string unit = "MiB";
                            double shownNow = mib, shownTot = totMib;
                            if (totMib >= 1024) {
                                unit = "GiB";
                                shownNow = mib / 1024.0;
                                shownTot = totMib / 1024.0;
                            }
                            _label.Text = string.Format(
                                "Computing SHA1... {0:N2} / {1:N2} {2}  ({3:N1}%)",
                                shownNow, shownTot, unit, permille / 10.0);
                            _detail.Text = string.Format(
                                "{0:N1} MiB/s   ~{1} remaining",
                                rate, FormatEta(remain));
                            Application.DoEvents();
                        }
                    }
                }

                byte[] hash = sha.Hash;
                System.Text.StringBuilder sb = new System.Text.StringBuilder(hash.Length * 2);
                for (int i = 0; i < hash.Length; i++) {
                    sb.Append(hash[i].ToString("x2"));
                }
                return sb.ToString();
            }
        }

        private static string FormatEta(double seconds) {
            if (double.IsInfinity(seconds) || double.IsNaN(seconds) || seconds < 0) return "?";
            if (seconds < 60) return string.Format("{0:N0}s", seconds);
            if (seconds < 3600) return string.Format("{0:N0}m {1:N0}s", Math.Floor(seconds / 60), seconds % 60);
            return string.Format("{0:N0}h {1:N0}m", Math.Floor(seconds / 3600), Math.Floor((seconds % 3600) / 60));
        }
    }
}
'@
}

function Show-Error([string]$message) {
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Create ISO - Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

$partialFile = $null
try {
    # --- Validate source ---------------------------------------------------
    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        throw "Folder not found: $FolderPath"
    }
    $source = (Resolve-Path -LiteralPath $FolderPath).Path.TrimEnd('\')
    $folderName = Split-Path -Leaf $source

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $parent = Split-Path -Parent $source
        if ([string]::IsNullOrEmpty($parent)) { $parent = (Get-Location).Path }
        $OutputPath = Join-Path $parent ("$folderName.iso")
    }
    $partialFile = $OutputPath

    if ([string]::IsNullOrWhiteSpace($VolumeName)) {
        $vn = ($folderName -replace '[^A-Za-z0-9_\-]', '_').ToUpperInvariant()
        if ($vn.Length -gt 32) { $vn = $vn.Substring(0, 32) }
        if ([string]::IsNullOrWhiteSpace($vn)) { $vn = 'ISO' }
        $VolumeName = $vn
    }

    # --- Show progress dialog ---------------------------------------------
    [CreateIso.Progress]::Show("Create ISO - $folderName")
    [CreateIso.Progress]::SetStatus("Scanning folder: $folderName")

    # --- Pre-scan for oversized files -------------------------------------
    # ISO9660 and Joliet cap individual files at 4 GiB - 1 byte. UDF supports
    # much larger. If anything in the tree is >= 4 GiB, drop ISO9660/Joliet
    # and build a UDF-only image so the job doesn't fail late.
    $isoMaxFile = 4GB - 1
    $largestFile = Get-ChildItem -LiteralPath $source -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object -Property Length -Descending | Select-Object -First 1
    $useUdfOnly = $largestFile -and ($largestFile.Length -gt $isoMaxFile)

    if ([CreateIso.Progress]::WasCanceled()) { throw [OperationCanceledException]::new("Canceled by user.") }

    # --- Build the file system image --------------------------------------
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.VolumeName = $VolumeName
    # IMAPI defaults FreeMediaBlocks to CD-ROM capacity (332,800 blocks ~
    # 650 MB). Raise it to INT32 max (2^31-1 sectors x 2048 B ~ 4 TiB) so
    # the image size is bounded only by the 32-bit sector counter.
    $fsi.FreeMediaBlocks = [int]::MaxValue
    if ($useUdfOnly) {
        # UDF only -- required when any file exceeds the 4 GiB ISO9660/Joliet
        # cap. Use UDF 2.50, which is what Windows itself writes for large
        # image media and which handles > 4 GiB files without issue.
        $fsi.UDFRevision = 0x250
        $fsi.FileSystemsToCreate = 4
        [CreateIso.Progress]::SetStatus(
            "Large file detected ($([math]::Round($largestFile.Length / 1GB, 2)) GiB) -- building UDF 2.50 image")
    } else {
        $fsi.UDFRevision = 0x102
        $fsi.FileSystemsToCreate = 7  # ISO9660 | Joliet | UDF
    }
    # Sanity-check that the assignment stuck (ChooseImageDefaults*, if ever
    # added back, will silently clobber this).
    if ($fsi.FreeMediaBlocks -lt 1000000) {
        throw "FreeMediaBlocks did not take effect (currently $($fsi.FreeMediaBlocks))."
    }

    if ([CreateIso.Progress]::WasCanceled()) { throw [OperationCanceledException]::new("Canceled by user.") }

    $root = $fsi.Root
    $root.AddTree($source, $false)  # contents at ISO root

    if ([CreateIso.Progress]::WasCanceled()) { throw [OperationCanceledException]::new("Canceled by user.") }

    [CreateIso.Progress]::SetStatus("Building image...")
    $result = $fsi.CreateResultImage()
    $imageStream = $result.ImageStream
    $totalBytes = [int64]$result.TotalBlocks * [int64]$result.BlockSize

    if ([CreateIso.Progress]::WasCanceled()) { throw [OperationCanceledException]::new("Canceled by user.") }

    # --- Write to disk with progress --------------------------------------
    $written = [CreateIso.Progress]::SaveStream($imageStream, $OutputPath, $totalBytes)

    [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($imageStream) | Out-Null
    [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($result) | Out-Null
    [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($fsi) | Out-Null

    # --- Hash the finished ISO and copy to clipboard ----------------------
    # Chunked hash so the WinForms dialog stays responsive and Cancel works.
    $sha1 = [CreateIso.Progress]::HashFileSha1($OutputPath)
    Set-Clipboard -Value $sha1

    # --- Write verbose hash sidecar ---------------------------------------
    $isoInfo    = Get-Item -LiteralPath $OutputPath
    $sizeBytes  = [int64]$isoInfo.Length
    $sizeGiB    = [math]::Round($sizeBytes / 1GB, 2)
    $sizeMiB    = [math]::Round($sizeBytes / 1MB, 2)
    $filesystem = if ($useUdfOnly) { 'UDF 2.50 (large-file mode)' } else { 'ISO9660 + Joliet + UDF 1.02' }
    $timestamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')

    $hashFile = "$OutputPath.sha1.txt"
    $lines = @(
        "File:        $($isoInfo.Name)"
        "Path:        $OutputPath"
        ("Size:        {0:N0} bytes  ({1:N2} GiB / {2:N2} MiB)" -f $sizeBytes, $sizeGiB, $sizeMiB)
        "SHA1:        $sha1"
        "Created:     $timestamp"
        "Source:      $source"
        "Volume:      $VolumeName"
        "Filesystem:  $filesystem"
        ""
        "# sha1sum -c compatible:"
        "$sha1 *$($isoInfo.Name)"
    )
    # UTF-8 without BOM so the file plays nicely with sha1sum and other
    # POSIX tools that don't expect a BOM.
    [System.IO.File]::WriteAllLines(
        $hashFile, [string[]]$lines,
        (New-Object System.Text.UTF8Encoding $false))

    [CreateIso.Progress]::Close()
    $partialFile = $null  # success -- keep the file
    exit 0
}
catch [OperationCanceledException] {
    [CreateIso.Progress]::Close()
    if ($partialFile -and (Test-Path -LiteralPath $partialFile)) {
        try { Remove-Item -LiteralPath $partialFile -Force -ErrorAction SilentlyContinue } catch { }
    }
    exit 2
}
catch {
    [CreateIso.Progress]::Close()
    if ($partialFile -and (Test-Path -LiteralPath $partialFile)) {
        try { Remove-Item -LiteralPath $partialFile -Force -ErrorAction SilentlyContinue } catch { }
    }
    Show-Error ("Failed to create ISO:`r`n`r`n" + $_.Exception.Message)
    exit 1
}
