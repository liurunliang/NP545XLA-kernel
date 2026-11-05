#requires -Version 5.1
# Inspect identifies the existing labelled volume. Preflight also hashes the
# source and opens the disk read-only. Write clears labelled media.
# ResumeCleared accepts only the same previously identified, empty USB disk.
[CmdletBinding()]
param(
    [ValidateSet('Inspect', 'Preflight', 'Write', 'ResumeCleared', 'Verify')]
    [string]$Mode = 'Inspect',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedLabel,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedModel,
    [Parameter(Mandatory)][long]$ExpectedBytes,
    [string]$ExpectedPath,
    [string]$ExpectedUniqueId,
    [string]$ImagePath,
    [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$Sha256
)
$ErrorActionPreference = 'Stop'
if ($ExpectedBytes -le 0) { throw 'ExpectedBytes must be positive.' }

function Get-TargetDisk {
    param([switch]$Labelled)
    if ($Labelled) {
        $volumes = @(Get-Volume | Where-Object { $_.FileSystemLabel -ceq $ExpectedLabel })
        if ($volumes.Count -ne 1) { throw "Expected exactly one volume labelled '$ExpectedLabel'." }
        $partitions = @(Get-Partition -Volume $volumes[0])
        if ($partitions.Count -ne 1) { throw 'Cannot map the labelled volume to exactly one partition.' }
        $disks = @(Get-Disk -Partition $partitions[0])
    } else {
        $disks = @(Get-Disk | Where-Object { $_.Path -eq $ExpectedPath })
    }
    if ($disks.Count -ne 1) { throw 'Cannot identify exactly one physical target disk.' }
    $disk = $disks[0]
    if ($disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem -or $disk.IsOffline -or
        $disk.FriendlyName.Trim() -ne $ExpectedModel -or $disk.Size -ne $ExpectedBytes) {
        throw 'USB bus, boot/system/online flags, model or capacity differ from the requested target.'
    }
    if (!$disk.Path -or !$disk.Path.StartsWith('\\?\') -or
        ($ExpectedPath -and $disk.Path -ne $ExpectedPath) -or
        ($ExpectedUniqueId -and $disk.UniqueId -ne $ExpectedUniqueId)) {
        throw 'Hardware device path or unique ID mismatch.'
    }
    if ($Labelled) {
        $all = @(Get-Partition -Disk $disk)
        if ($all.Count -ne 1 -or $all[0].PartitionNumber -ne $partitions[0].PartitionNumber -or
            $all[0].IsBoot -or $all[0].IsSystem) { throw 'Expected just the one non-system partition.' }
        foreach ($pageFile in @(Get-CimInstance Win32_PageFileUsage)) {
            $backing = @(Get-Volume -FilePath $pageFile.Name | Get-Partition | Get-Disk)
            if ($backing.Count -ne 1 -or $backing[0].Path -eq $disk.Path) {
                throw "Cannot rule out an active page file on the target: $($pageFile.Name)"
            }
        }
    }
    return $disk
}

function Assert-ClearedDisk($d) {
    # Removable drives can retain an initialized MBR or GPT after Clear-Disk.
    if ($d.PartitionStyle -notin @('RAW','MBR','GPT') -or $d.NumberOfPartitions -ne 0) {
        throw "Expected an empty USB disk (style=$($d.PartitionStyle), partitions=$($d.NumberOfPartitions))."
    }
}

if ($Mode -eq 'Inspect') {
    Get-TargetDisk -Labelled | Select-Object Number,FriendlyName,Size,BusType,LogicalSectorSize,PhysicalSectorSize,Path,UniqueId,IsBoot,IsSystem
    return
}
if (!$ExpectedPath -or !$ImagePath -or !$Sha256) { throw 'Supply -ExpectedPath from Inspect, -ImagePath and -Sha256.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (!([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open an elevated Windows PowerShell session.'
}

# Windows raw disks require an OPEN_EXISTING handle, sector-sized transfers
# and (for bypassing cache) an aligned buffer. VirtualAlloc is page-aligned.
# Use the disk device interface string rather than a reusable disk number.
if (!('Np545xlaDiskIO' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

public static class Np545xlaDiskIO {
    const int Chunk = 1024 * 1024;
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadFile(SafeFileHandle handle, IntPtr buffer, int count, out int done, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteFile(SafeFileHandle handle, IntPtr buffer, int count, out int done, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool FlushFileBuffers(SafeFileHandle handle);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint allocType, uint protect);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint freeType);

    // With no source this is a read-only hash of exactly length bytes.
    public static string Transfer(string path, long length, int alignment, FileStream source) {
        if (alignment <= 0 || Chunk % alignment != 0 || length <= 0 || length % alignment != 0)
            throw new InvalidDataException("Length and transfer size must be sector-aligned.");
        uint access = source == null ? 0x80000000u : 0xc0000000u;
        uint flags = source == null ? 0x20000000u : 0xa0000000u; // NO_BUFFERING + WRITE_THROUGH on write
        using (SHA256 hash = SHA256.Create())
        using (SafeFileHandle disk = CreateFile(path, access, 3, IntPtr.Zero, 3, flags, IntPtr.Zero)) {
            if (disk.IsInvalid) throw new Win32Exception();
            var data = new byte[Chunk];
            IntPtr buffer = VirtualAlloc(IntPtr.Zero, new UIntPtr(Chunk), 0x3000, 4);
            if (buffer == IntPtr.Zero) throw new Win32Exception();
            try {
                if (buffer.ToInt64() % alignment != 0) throw new IOException("Unaligned I/O buffer.");
                for (long offset = 0; offset < length; ) {
                    int count = (int)Math.Min(Chunk, length - offset);
                    int done;
                    if (source == null) {
                        if (!ReadFile(disk, buffer, count, out done, IntPtr.Zero)) throw new Win32Exception();
                        if (done != count) throw new EndOfStreamException("Short disk read at " + offset);
                        Marshal.Copy(buffer, data, 0, count);
                        hash.TransformBlock(data, 0, count, data, 0);
                    } else {
                        for (int filled = 0; filled < count; ) {
                            int got = source.Read(data, filled, count - filled);
                            if (got == 0) throw new EndOfStreamException("Unexpected end of source image.");
                            filled += got;
                        }
                        Marshal.Copy(data, 0, buffer, count);
                        if (!WriteFile(disk, buffer, count, out done, IntPtr.Zero)) throw new Win32Exception();
                        if (done != count) throw new IOException("Short disk write at " + offset);
                    }
                    offset += count;
                }
                if (source != null) {
                    if (!FlushFileBuffers(disk)) throw new Win32Exception();
                    return null;
                }
                hash.TransformFinalBlock(data, 0, 0);
                return BitConverter.ToString(hash.Hash).Replace("-", "");
            } finally { VirtualFree(buffer, UIntPtr.Zero, 0x8000); }
        }
    }
}
'@
}

if ($Mode -eq 'ResumeCleared' -and !$ExpectedUniqueId) { throw 'Resume requires the hardware unique ID recorded by Inspect.' }
$disk = Get-TargetDisk -Labelled:($Mode -in @('Preflight', 'Write'))
if ($Mode -eq 'ResumeCleared') { Assert-ClearedDisk $disk }
$file = Get-Item -LiteralPath $ImagePath
if (!($file -is [IO.FileInfo])) { throw 'Expected a regular local image file.' }
$sourceDisk = @(Get-Volume -FilePath $file.FullName | Get-Partition | Get-Disk)
if ($sourceDisk.Count -ne 1 -or $sourceDisk[0].Path -eq $disk.Path) {
    throw 'Stage the image on a separate local disk.'
}
# Keep the validated source open with no write/delete sharing through write and verification.
$source = [IO.File]::Open($file.FullName, 'Open', 'Read', 'Read')
try {
    $length = $source.Length
    $sector = [int][Math]::Max([long]$disk.LogicalSectorSize, [long]$disk.PhysicalSectorSize)
    if ($sector -le 0 -or $length -le 0 -or $length -gt $disk.Size -or $length % $sector -ne 0) {
        throw 'Image size does not fit the target or is not sector-aligned.'
    }
    $hash = (Get-FileHash -Algorithm SHA256 -InputStream $source).Hash
    if ($hash -ne $Sha256) { throw "Source SHA256 differs from the expected hash: $hash" }
    $source.Position = 0
    [void][Np545xlaDiskIO]::Transfer($disk.Path, $sector, $sector, $null)
    if ($Mode -eq 'Preflight') {
        if ($disk.IsReadOnly) { throw 'The target is read-only.' }
        [pscustomobject]@{Result='Preflight OK'; Target=$disk.Path; ImageBytes=$length; SHA256=$hash}
        return
    }
    if ($Mode -eq 'Write') {
        $disk = Get-TargetDisk -Labelled
        if ($disk.IsReadOnly) { throw 'The target is read-only.' }
        Write-Host "Clearing $ExpectedLabel on $($disk.Path), then writing $length bytes."
        Clear-Disk -InputObject $disk -RemoveData -Confirm:$false
    }
    if ($Mode -in @('Write','ResumeCleared')) {
        $disk = Get-TargetDisk
        Assert-ClearedDisk $disk
        if ($disk.IsReadOnly) { throw 'The target is read-only.' }
        [void][Np545xlaDiskIO]::Transfer($disk.Path, $length, $sector, $source)
        # Raw verification must precede any partition rescan. On a larger USB,
        # Windows rewrites GPT BackupLBA/LastUsableLBA and HeaderCRC32 on rescan.
    }
    # Open the same hardware path again, uncached, without asking Windows to refresh its GPT.
    $readback = [Np545xlaDiskIO]::Transfer($disk.Path, $length, $sector, $null)
    if ($readback -ne $Sha256) { throw "Readback SHA256 mismatch: $readback" }
    [pscustomobject]@{Result='Verified'; Target=$disk.Path; ImageBytes=$length; SourceSHA256=$hash; ReadbackSHA256=$readback}
} finally {
    $source.Dispose()
}
