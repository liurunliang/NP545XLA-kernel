# Read-only NP545XLA Windows Bluetooth baseline, with two optional BR/EDR inquiries.
# No pairing, driver replacement, registry changes, radio reset, or boot changes.
# Reports contain only scoped device/driver data and the requested device match.
param(
    [string]$KnownName = '[Signage] Samsung QMR Series',
    [string]$UploadUri = '',
    [switch]$SkipInquiry,
    [switch]$InquiryOnly,
    [ValidateRange(1,48)][byte]$InquiryTimeoutMultiplier = 10
)
$ErrorActionPreference = 'Stop'
$runStarted = Get-Date
if ($SkipInquiry -and $InquiryOnly) { throw 'Choose either SkipInquiry or InquiryOnly.' }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Run this collector on Windows.' }
$outDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('NP545-Bluetooth\' + $runStarted.ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $outDir | Out-Null
function Save-Result([string]$Name, [scriptblock]$Read) {
    try {
        $value = & $Read
        ConvertTo-Json -InputObject $value -Depth 12 | Set-Content -LiteralPath (Join-Path $outDir ($Name + '.json')) -Encoding UTF8
    } catch {
        ($Name + ': ' + $_.Exception.ToString()) | Add-Content -LiteralPath (Join-Path $outDir 'errors.txt') -Encoding UTF8
        Write-Host ($Name + ': ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}
if ($InquiryOnly) { Write-Host 'Reading local Bluetooth radio information...' }
else { Write-Host 'Reading local Bluetooth, UART and driver information...' }
Save-Result 'system' {
    [ordered]@{
        StartedUtc=$runStarted.ToUniversalTime().ToString('o')
        StartedLocal=$runStarted.ToString('o')
        PowerShellVersion=$PSVersionTable.PSVersion.ToString()
        Is64BitProcess=[Environment]::Is64BitProcess
        OS=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,LastBootUpTime)
        Computer=(Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,SystemType)
        BIOS=(Get-CimInstance Win32_BIOS | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate)
        KnownDevice=$KnownName
        InquiryOnly=[bool]$InquiryOnly
        InquiryTimeoutMultiplier=$InquiryTimeoutMultiplier
        InquiryNote='BR/EDR inquiry API only; does not discover BLE-only devices. Cached matches are not automatically accepted as live observations. Inspect last-seen fields and compare both rounds.'
        VersionNote='Windows LMP/HCI runtime versions are not the pre-firmware FC00 boot-ROM reply requested by Linux.'
    }
}
if (-not $InquiryOnly) {
    $devices = @()
    Save-Result 'devices' {
        $script:devices = @(Get-PnpDevice -PresentOnly | Where-Object {
            $_.InstanceId -match '^ACPI\\QCOM(0471|0418|0403)' -or
            ($_.Class -eq 'Bluetooth' -and $_.InstanceId -notmatch '^(BTHENUM|BTHLEDEVICE)\\')
        })
        $devices | Select-Object Status,Class,FriendlyName,InstanceId,Problem,ConfigManagerErrorCode
    }
    $deviceProperties = @()
    foreach ($device in $devices) {
        try {
            $props = @(Get-PnpDeviceProperty -InstanceId $device.InstanceId | Select-Object KeyName,Type,Data)
            $deviceProperties += [ordered]@{InstanceId=$device.InstanceId; Properties=$props}
        } catch {
            ($device.InstanceId + ': ' + $_) | Add-Content -LiteralPath (Join-Path $outDir 'errors.txt') -Encoding UTF8
        }
    }
    Save-Result 'device-properties' { $deviceProperties }
    Save-Result 'signed-drivers' {
        Get-CimInstance Win32_PnPSignedDriver | Where-Object { $devices.InstanceId -contains $_.DeviceID } |
            Select-Object DeviceID,DeviceName,DriverVersion,DriverDate,DriverProviderName,InfName,IsSigned,Manufacturer
    }
    $ordinal=0
    foreach ($device in $devices) {
        $ordinal++
        try {
            $text = & pnputil.exe /enum-devices /instanceid $device.InstanceId /properties /resources /drivers 2>&1
            ('Instance: ' + $device.InstanceId),('Exit: ' + $LASTEXITCODE),$text |
                Out-File -LiteralPath (Join-Path $outDir ('resources-' + $ordinal + '.txt')) -Encoding UTF8
        } catch {
            $_ | Out-String | Out-File -LiteralPath (Join-Path $outDir ('resources-' + $ordinal + '.txt')) -Encoding UTF8
        }
    }
    $serviceNames = @('QcBluetooth','qcuart','qcgpio','bthport')
    foreach ($entry in $deviceProperties) {
        $serviceNames += @($entry.Properties | Where-Object {$_.KeyName -eq 'DEVPKEY_Device_Service'} | ForEach-Object {$_.Data})
    }
    $serviceNames = @($serviceNames | Where-Object {$_} | Sort-Object -Unique)
    Save-Result 'device-settings' {
        foreach ($device in $devices) {
            $enumKey='HKLM:\SYSTEM\CurrentControlSet\Enum\' + $device.InstanceId
            $keys=@(($enumKey+'\Parameters'),($enumKey+'\Device Parameters'),($enumKey+'\Instance'))
            $driverKey=(Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_Driver' -ErrorAction SilentlyContinue).Data
            if ($driverKey) { $keys += 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $driverKey + '\Parameters' }
            foreach ($key in $keys) {
                if (Test-Path -LiteralPath $key) {
                    [ordered]@{InstanceId=$device.InstanceId;Key=$key;Values=(Get-ItemProperty -LiteralPath $key | Select-Object * -ExcludeProperty PSPath,PSParentPath,PSChildName,PSDrive,PSProvider)}
                    Get-ChildItem -LiteralPath $key -Recurse | Select-Object -First 32 | ForEach-Object {
                        [ordered]@{InstanceId=$device.InstanceId;Key=$_.Name;Values=(Get-ItemProperty -LiteralPath $_.PSPath | Select-Object * -ExcludeProperty PSPath,PSParentPath,PSChildName,PSDrive,PSProvider)}
                    }
                }
            }
        }
    }
    Save-Result 'service-parameters' {
        # Limit registry reads to vendor services; never traverse BTHPORT pairing keys.
        foreach ($serviceName in @('QcBluetooth','qcuart','qcgpio')) {
            $key='HKLM:\SYSTEM\CurrentControlSet\Services\' + $serviceName
            if (Test-Path -LiteralPath $key) {
                $service=Get-ItemProperty -LiteralPath $key
                $items=@()
                $parameters=Join-Path $key 'Parameters'
                if (Test-Path -LiteralPath $parameters) {
                    $items += Get-ItemProperty -LiteralPath $parameters | Select-Object * -ExcludeProperty PSPath,PSParentPath,PSChildName,PSDrive,PSProvider
                    $items += Get-ChildItem -LiteralPath $parameters -Recurse | Select-Object -First 64 | ForEach-Object {
                        [ordered]@{Key=$_.Name; Values=(Get-ItemProperty -LiteralPath $_.PSPath | Select-Object * -ExcludeProperty PSPath,PSParentPath,PSChildName,PSDrive,PSProvider)}
                    }
                }
                [ordered]@{Service=$serviceName;ImagePath=$service.ImagePath;Parameters=$items}
            }
        }
    }
    Save-Result 'driver-files' {
        Get-CimInstance Win32_SystemDriver | Where-Object {$serviceNames -contains $_.Name} | ForEach-Object {
            $path=$_.PathName.Trim('"')
            if ($path.StartsWith('\SystemRoot\',[StringComparison]::OrdinalIgnoreCase)) { $path=$env:windir + $path.Substring(11) }
            if ($path.StartsWith('\??\')) { $path=$path.Substring(4) }
            $hash=$null; $version=$null
            if (Test-Path -LiteralPath $path) {
                $hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
                $version=(Get-Item -LiteralPath $path).VersionInfo.FileVersion
            }
            [ordered]@{Service=$_.Name;State=$_.State;Path=$path;FileVersion=$version;SHA256=$hash}
        }
    }
    Save-Result 'radio-services' { Get-Service bthserv -ErrorAction SilentlyContinue | Select-Object Name,Status }
}
$nativeSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class NP545BluetoothBaseline {
    [StructLayout(LayoutKind.Sequential)] public struct RadioFindParams { public uint Size; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct RadioInfo {
        public uint Size; public ulong Address;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=248)] public string Name;
        public uint ClassOfDevice; public ushort LmpSubversion; public ushort Manufacturer;
    }
    [StructLayout(LayoutKind.Sequential)] public struct SystemTime {
        public ushort Year, Month, DayOfWeek, Day, Hour, Minute, Second, Milliseconds;
        public override string ToString() {
            return String.Format("{0:D4}-{1:D2}-{2:D2}T{3:D2}:{4:D2}:{5:D2}.{6:D3}",
                Year,Month,Day,Hour,Minute,Second,Milliseconds);
        }
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DeviceInfo {
        public uint Size; public ulong Address; public uint ClassOfDevice;
        [MarshalAs(UnmanagedType.Bool)] public bool Connected;
        [MarshalAs(UnmanagedType.Bool)] public bool Remembered;
        [MarshalAs(UnmanagedType.Bool)] public bool Authenticated;
        public SystemTime LastSeen, LastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=248)] public string Name;
    }
    [StructLayout(LayoutKind.Sequential)] public struct SearchParams {
        public uint Size;
        [MarshalAs(UnmanagedType.Bool)] public bool ReturnAuthenticated;
        [MarshalAs(UnmanagedType.Bool)] public bool ReturnRemembered;
        [MarshalAs(UnmanagedType.Bool)] public bool ReturnUnknown;
        [MarshalAs(UnmanagedType.Bool)] public bool ReturnConnected;
        [MarshalAs(UnmanagedType.Bool)] public bool IssueInquiry;
        public byte TimeoutMultiplier; public IntPtr Radio;
    }
    public class Match {
        public string Name, Address, LastSeenRaw, LastUsedRaw;
        public bool Connected, Remembered, Authenticated;
    }
    public class Round {
        public int Number, Error, EnumeratedCount, TimeoutMultiplier;
        public long ElapsedMilliseconds;
        public string StartUtc, StartLocal, EndUtc;
        public List<Match> Matches = new List<Match>();
    }
    public class RadioResult {
        public string Name, Address; public int RadioInfoError;
        public ushort LmpSubversion, Manufacturer;
        public List<Round> Rounds = new List<Round>();
    }
    [DllImport("bthprops.cpl", SetLastError=true)] static extern IntPtr BluetoothFindFirstRadio(ref RadioFindParams p, out IntPtr radio);
    [DllImport("bthprops.cpl", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool BluetoothFindNextRadio(IntPtr find, out IntPtr radio);
    [DllImport("bthprops.cpl")] [return:MarshalAs(UnmanagedType.Bool)] static extern bool BluetoothFindRadioClose(IntPtr find);
    [DllImport("bthprops.cpl")] static extern uint BluetoothGetRadioInfo(IntPtr radio, ref RadioInfo info);
    [DllImport("bthprops.cpl", SetLastError=true)] static extern IntPtr BluetoothFindFirstDevice(ref SearchParams p, ref DeviceInfo info);
    [DllImport("bthprops.cpl", SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool BluetoothFindNextDevice(IntPtr find, ref DeviceInfo info);
    [DllImport("bthprops.cpl")] [return:MarshalAs(UnmanagedType.Bool)] static extern bool BluetoothFindDeviceClose(IntPtr find);
    [DllImport("kernel32.dll")] [return:MarshalAs(UnmanagedType.Bool)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint GetSystemFirmwareTable(uint provider, uint table, IntPtr data, uint size);
    public static string AddressText(ulong address) {
        string h=address.ToString("X12");
        return String.Join(":",new string[]{h.Substring(0,2),h.Substring(2,2),h.Substring(4,2),h.Substring(6,2),h.Substring(8,2),h.Substring(10,2)});
    }
    public static void CheckLayouts() {
        if (IntPtr.Size!=8 || Marshal.SizeOf(typeof(RadioInfo))!=520 ||
            Marshal.SizeOf(typeof(DeviceInfo))!=560 || Marshal.SizeOf(typeof(SearchParams))!=40)
            throw new InvalidOperationException("Unexpected native structure layout; run 64-bit Windows PowerShell.");
    }
    public static List<RadioResult> Scan(string knownName, byte timeoutMultiplier) {
        CheckLayouts();
        if (timeoutMultiplier<1 || timeoutMultiplier>48) throw new ArgumentOutOfRangeException("timeoutMultiplier");
        var result=new List<RadioResult>();
        var p=new RadioFindParams { Size=(uint)Marshal.SizeOf(typeof(RadioFindParams)) };
        IntPtr radio; IntPtr find=BluetoothFindFirstRadio(ref p,out radio);
        if (find==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"No local Bluetooth radio was enumerated");
        try {
            do {
                try {
                    var info=new RadioInfo { Size=(uint)Marshal.SizeOf(typeof(RadioInfo)) };
                    var item=new RadioResult(); item.RadioInfoError=(int)BluetoothGetRadioInfo(radio,ref info);
                    item.Name=info.Name; item.Address=AddressText(info.Address);
                    item.LmpSubversion=info.LmpSubversion; item.Manufacturer=info.Manufacturer;
                    for (int round=1;round<=2;round++) {
                        var r=new Round { Number=round,TimeoutMultiplier=timeoutMultiplier,StartUtc=DateTime.UtcNow.ToString("o"),StartLocal=DateTime.Now.ToString("o") };
                        var timer=System.Diagnostics.Stopwatch.StartNew();
                        var search=new SearchParams { Size=(uint)Marshal.SizeOf(typeof(SearchParams)),
                            ReturnAuthenticated=true,ReturnRemembered=true,ReturnUnknown=true,ReturnConnected=true,
                            IssueInquiry=true,TimeoutMultiplier=timeoutMultiplier,Radio=radio };
                        var device=new DeviceInfo { Size=(uint)Marshal.SizeOf(typeof(DeviceInfo)) };
                        IntPtr devices=BluetoothFindFirstDevice(ref search,ref device);
                        if (devices==IntPtr.Zero) r.Error=Marshal.GetLastWin32Error();
                        else {
                            try {
                                do {
                                    r.EnumeratedCount++;
                                    if (String.Equals(device.Name,knownName,StringComparison.OrdinalIgnoreCase))
                                        r.Matches.Add(new Match { Name=device.Name,Address=AddressText(device.Address),
                                            LastSeenRaw=device.LastSeen.ToString(),LastUsedRaw=device.LastUsed.ToString(),
                                            Connected=device.Connected,Remembered=device.Remembered,Authenticated=device.Authenticated });
                                    device.Size=(uint)Marshal.SizeOf(typeof(DeviceInfo));
                                } while (BluetoothFindNextDevice(devices,ref device));
                                int error=Marshal.GetLastWin32Error(); if (error!=259) r.Error=error;
                            } finally { BluetoothFindDeviceClose(devices); }
                        }
                        r.EndUtc=DateTime.UtcNow.ToString("o"); r.ElapsedMilliseconds=timer.ElapsedMilliseconds; item.Rounds.Add(r);
                        if (round==1) Thread.Sleep(3000);
                    }
                    result.Add(item);
                } finally { CloseHandle(radio); }
            } while (result.Count<4 && BluetoothFindNextRadio(find,out radio));
        } finally { BluetoothFindRadioClose(find); }
        return result;
    }
    public static void ReadDsdt(string path) {
        uint size=GetSystemFirmwareTable(0x41435049,0x54445344,IntPtr.Zero,0);
        if (size==0) throw new Win32Exception(Marshal.GetLastWin32Error(),"DSDT is not available through the firmware table API");
        if (size<36 || size>2097152) throw new InvalidOperationException("Unexpected DSDT length");
        IntPtr data=Marshal.AllocHGlobal((int)size);
        try {
            uint actual=GetSystemFirmwareTable(0x41435049,0x54445344,data,size);
            if (actual!=size) throw new InvalidOperationException("DSDT size changed during read");
            byte[] bytes=new byte[size]; Marshal.Copy(data,bytes,0,(int)size);
            if (bytes[0]!=68 || bytes[1]!=83 || bytes[2]!=68 || bytes[3]!=84) throw new InvalidOperationException("Unexpected firmware signature");
            File.WriteAllBytes(path,bytes);
        } finally { Marshal.FreeHGlobal(data); }
    }
}
'@
Save-Result 'native-layouts' {
    if (-not ('NP545BluetoothBaseline' -as [type])) { Add-Type -TypeDefinition $nativeSource }
    [NP545BluetoothBaseline]::CheckLayouts()
    'Validated 64-bit layouts: radio 520, device 560, search 40 bytes'
}
if (-not $InquiryOnly) {
    Save-Result 'firmware-table' {
        $dsdt=Join-Path $outDir 'DSDT.dat'
        [NP545BluetoothBaseline]::ReadDsdt($dsdt)
        Get-FileHash -Algorithm SHA256 -LiteralPath $dsdt | Select-Object Algorithm,Hash
    }
}
if (-not $SkipInquiry) {
    Write-Host ('Keep ' + $KnownName + ' discoverable. Running two Bluetooth inquiries...')
    Save-Result 'bluetooth-inquiries' { [NP545BluetoothBaseline]::Scan($KnownName,$InquiryTimeoutMultiplier) }
}
if (-not $InquiryOnly) {
    Save-Result 'recent-bluetooth-events' {
        @(Get-WinEvent -FilterHashtable @{LogName='System';StartTime=$runStarted.AddMinutes(-15)} -MaxEvents 800 -ErrorAction SilentlyContinue |
            Where-Object {$_.ProviderName -match 'Bluetooth|BTH|qcuart|qcbt'} |
            Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message)
    }
}
$archive=$outDir + '.zip'
Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $archive
Write-Host ('Report: ' + $archive)
if ($UploadUri) {
    try {
        $endpoint=[uri]$UploadUri
        if ($endpoint.Scheme -ne 'http' -or $endpoint.Host -notmatch '^10\.86\.\d{1,3}\.\d{1,3}$') { throw 'Expected the private LAN address of the diagnostic Mac.' }
        Invoke-WebRequest -UseBasicParsing -Method Post -Uri $endpoint -InFile $archive -ContentType 'application/zip' -TimeoutSec 30 | Out-Null
        Write-Host 'Report received by the diagnostic Mac.' -ForegroundColor Green
    } catch {
        Write-Host ('Upload did not complete: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ('The report remains at: ' + $archive)
    }
}
