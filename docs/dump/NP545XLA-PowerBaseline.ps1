# Read-only Windows power baseline for NP545XLA.
# Saves reports locally. Does not suspend, reboot, change settings, or access I2C.
# Before: .\NP545XLA-PowerBaseline.ps1 -Phase Before
# After:  .\NP545XLA-PowerBaseline.ps1 -Phase After -TrialDirectory '<printed path>'
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Before', 'After')][string]$Phase,
    [string]$TrialDirectory = ''
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Run this collector on the NP545XLA in Windows.'
}
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run in an Administrator PowerShell window so powercfg can generate reports.'
}
$computer = Get-CimInstance Win32_ComputerSystem
$board = Get-CimInstance Win32_BaseBoard
if ($computer.Manufacturer -notmatch '^SAMSUNG' -or
    ($computer.Model -notmatch 'NP545XLA|545XLA' -and $board.Product -notmatch '^NP545XLA(?:-|$)')) {
    throw ('Unexpected model/board: ' + $computer.Model + ' / ' + $board.Product)
}

# Qualcomm's miniclass driver may expose no root\wmi BatteryStatus instances.
# Query the documented aggregate battery state as a separate telemetry source.
if (-not ('NP545PowerBaseline.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace NP545PowerBaseline {
    [StructLayout(LayoutKind.Sequential)]
    public struct BatteryState {
        public byte AcOnLine, BatteryPresent, Charging, Discharging;
        public byte Spare0, Spare1, Spare2, Tag;
        public uint MaxCapacity, RemainingCapacity, Rate, EstimatedTime;
        public uint DefaultAlert1, DefaultAlert2;
        public int SignedRate { get { return unchecked((int)Rate); } }
    }
    public static class Native {
        [DllImport("powrprof.dll", ExactSpelling=true)]
        private static extern uint CallNtPowerInformation(
            int level, IntPtr input, uint inputLength,
            out BatteryState output, uint outputLength);
        public static BatteryState ReadBattery() {
            int size = Marshal.SizeOf(typeof(BatteryState));
            if (size != 32) throw new InvalidOperationException("Unexpected battery structure size.");
            BatteryState state;
            // SystemBatteryState=5 is a query; no input or policy setter is used.
            uint status = CallNtPowerInformation(5, IntPtr.Zero, 0, out state, (uint)size);
            if (status != 0) throw new InvalidOperationException(
                "SystemBatteryState NTSTATUS 0x" + status.ToString("X8"));
            return state;
        }
    }
}
'@
}
$started = Get-Date
$scriptFile = $PSCommandPath
if ($Phase -eq 'Before') {
    if ($TrialDirectory) { throw 'Before creates a new trial; do not supply TrialDirectory.' }
    $TrialDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) (
        'NP545-Power\' + $started.ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $TrialDirectory | Out-Null
} else {
    if (-not $TrialDirectory) { throw 'After requires the directory printed by Before.' }
    $TrialDirectory = (Resolve-Path -LiteralPath $TrialDirectory).Path
    if (-not (Test-Path -LiteralPath (Join-Path $TrialDirectory 'before\complete.json'))) {
        throw 'No completed Before collection in this directory.'
    }
}
$phaseDir = Join-Path $TrialDirectory $Phase.ToLowerInvariant()
if (Test-Path -LiteralPath $phaseDir) { throw 'This phase already exists; retain it and start a new trial.' }
New-Item -ItemType Directory -Path $phaseDir | Out-Null
$script:problems = @()

function Save-Json([string]$Name, [scriptblock]$Read) {
    try {
        $value = & $Read
        ConvertTo-Json -InputObject $value -Depth 12 |
            Set-Content -LiteralPath (Join-Path $phaseDir ($Name + '.json')) -Encoding UTF8
    } catch {
        $script:problems += [ordered]@{ Item=$Name; Error=$_.Exception.Message }
        Write-Warning ($Name + ': ' + $_.Exception.Message)
    }
}

function Save-Battery([string]$Name) {
    Save-Json ($Name + '-system') {
        $sampleTime = (Get-Date).ToUniversalTime().ToString('o')
        $state = [NP545PowerBaseline.Native]::ReadBattery()
        if ($state.BatteryPresent -eq 0) { throw 'SystemBatteryState reports no battery.' }
        [ordered]@{
            TimestampUtc=$sampleTime
            Source='CallNtPowerInformation(SystemBatteryState=5)'
            State=$state
            Note='Windows aggregate battery telemetry; may be cached. Rate is raw DWORD; SignedRate is LONG in mW. Not direct SBS or charger registers.'
        }
    }
    Save-Json $Name {
        [ordered]@{
            TimestampUtc=(Get-Date).ToUniversalTime().ToString('o')
            Status=@(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus |
                Select-Object InstanceName,Active,PowerOnline,Charging,Discharging,
                    Critical,Voltage,RemainingCapacity,Rate,ChargeRate,DischargeRate)
            Note='Windows driver/WMI telemetry; may be cached or contain no instances. See the separate system battery sample. Not direct SBS or charger registers.'
        }
    }
}

function Save-Powercfg([string]$Name, [string[]]$Arguments) {
    try {
        # An argv array avoids interpreting paths or output as PowerShell code.
        $lines = & "$env:SystemRoot\System32\powercfg.exe" @Arguments 2>&1
        $code = $LASTEXITCODE
        @(('ExitCode: ' + $code), ('Arguments: ' + ($Arguments -join ' ')), $lines) |
            Out-File -LiteralPath (Join-Path $phaseDir ($Name + '.txt')) -Encoding UTF8
        if ($code -ne 0) {
            $script:problems += [ordered]@{ Item=$Name; Error=('powercfg exit ' + $code) }
        }
    } catch {
        $script:problems += [ordered]@{ Item=$Name; Error=$_.Exception.Message }
    }
}

function Resolve-EmuEcImagePath([string]$RawPath, [string]$WindowsDirectory) {
    # Treat the service ImagePath as data, never as a command line to execute.
    $imagePath = [Environment]::ExpandEnvironmentVariables($RawPath.Trim()).Trim('"')
    if ($imagePath.StartsWith('\??\', [StringComparison]::Ordinal)) {
        $imagePath = $imagePath.Substring(4)
    }
    if ($imagePath.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        $imagePath = $WindowsDirectory.TrimEnd('\') + '\' + $imagePath.Substring(12)
    } elseif ($imagePath.StartsWith('System32\', [StringComparison]::OrdinalIgnoreCase)) {
        $imagePath = $WindowsDirectory.TrimEnd('\') + '\' + $imagePath
    }
    if ($imagePath -notmatch '^[A-Za-z]:\\[^:"*?<>|]+\\EmuEC\.sys$') {
        throw ('Unrecognized EmuEC image path; retain the raw service record: ' + $RawPath)
    }
    return $imagePath
}

# Take the first sample before the slower inventory/report operations.
Save-Battery 'battery-first'
Save-Json 'system' {
    [ordered]@{
        Phase=$Phase
        StartedUtc=$started.ToUniversalTime().ToString('o')
        Computer=($computer | Select-Object Manufacturer,Model,SystemType)
        Board=($board | Select-Object Manufacturer,Product,Version)
        OS=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,LastBootUpTime)
        BIOS=(Get-CimInstance Win32_BIOS | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate)
        ScriptSHA256=(Get-FileHash -Algorithm SHA256 -LiteralPath $scriptFile).Hash
    }
}
Save-Json 'battery-capacity' {
    Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity |
        Select-Object InstanceName,Active,FullChargedCapacity
}
Save-Json 'battery-summary' {
    Get-CimInstance Win32_Battery |
        Select-Object Name,Manufacturer,BatteryStatus,EstimatedChargeRemaining,DesignVoltage
}
Save-Powercfg 'available-sleep-states' @('/a')
Save-Powercfg 'power-requests' @('/requests')
Save-Powercfg 'active-scheme' @('/getactivescheme')
Save-Powercfg 'sleep-settings' @('/query', 'SCHEME_CURRENT', 'SUB_SLEEP')
Save-Powercfg 'lid-button-settings' @('/query', 'SCHEME_CURRENT', 'SUB_BUTTONS')
Save-Powercfg 'last-wake' @('/lastwake')

Save-Json 'devices' {
    Get-PnpDevice -PresentOnly | Where-Object {
        $_.InstanceId -match '^ACPI\\(SAM060[46]|QCOM0263|QCOM0419|QCOM049A|PNP0C0A)\\'
    } | Select-Object Status,Class,FriendlyName,InstanceId,Problem
}
Save-Json 'drivers' {
    Get-CimInstance Win32_PnPSignedDriver | Where-Object {
        $_.DeviceID -match '^ACPI\\(SAM060[46]|QCOM0263|QCOM0419|QCOM049A|PNP0C0A)\\'
    } | Select-Object DeviceID,DeviceName,DriverVersion,DriverDate,DriverProviderName,InfName,IsSigned
}
Save-Json 'emuec-service' {
    $driver = Get-CimInstance Win32_SystemDriver -Filter "Name='EmuEC'"
    if (-not $driver) { throw 'EmuEC system-driver service was not found.' }
    $diskImage = $null
    $imageError = $null
    try {
        $imagePath = Resolve-EmuEcImagePath $driver.PathName $env:SystemRoot
        $file = Get-Item -LiteralPath $imagePath
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $imagePath).Hash
        $analyzedHash = '70de2be234da9d34125b4409f1272f8e74b2a7f1f1c651f9f09548823cb58bb9'
        $diskImage = [ordered]@{
            Path=$file.FullName; Length=$file.Length; SHA256=$hash
            FileVersion=$file.VersionInfo.FileVersion
            MatchesAnalyzedBinary=($hash -eq $analyzedHash)
            AnalyzedSHA256=$analyzedHash
        }
    } catch {
        $imageError = $_.Exception.Message
        $script:problems += [ordered]@{ Item='emuec-image'; Error=$imageError }
    }
    [ordered]@{
        TimestampUtc=(Get-Date).ToUniversalTime().ToString('o')
        Service=($driver | Select-Object Name,DisplayName,State,Started,StartMode,PathName)
        ImageOnDisk=$diskImage; ImageReadError=$imageError
        Note='Hashes the service image on disk, not loaded memory. A different hash requires renewed WPP analysis.'
    }
}
Save-Json 'trace-tools' {
    foreach ($toolName in @('wpr.exe', 'tracelog.exe', 'tracefmt.exe')) {
        $commands = @(Get-Command -Name $toolName -CommandType Application -All -ErrorAction SilentlyContinue)
        [ordered]@{
            Name=$toolName; Paths=@($commands | ForEach-Object { $_.Source })
            Note='Discovery only; no trace started. Empty means not found through command lookup, not necessarily uninstalled.'
        }
    }
}

if ($Phase -eq 'After') {
    $before = Get-Content -Raw -LiteralPath (Join-Path $TrialDirectory 'before\complete.json') | ConvertFrom-Json
    $since = [DateTimeOffset]::Parse($before.CompletedUtc).LocalDateTime.AddMinutes(-2)
    Save-Json 'power-events' {
        Get-WinEvent -FilterHashtable @{
            LogName='System'; StartTime=$since
            ProviderName=@('Microsoft-Windows-Kernel-Power', 'Microsoft-Windows-Power-Troubleshooter',
                'Microsoft-Windows-Kernel-Boot')
        } -MaxEvents 1000 | ForEach-Object {
            [ordered]@{ TimeUtc=$_.TimeCreated.ToUniversalTime().ToString('o');
                Provider=$_.ProviderName; Id=$_.Id; Xml=$_.ToXml() }
        }
    }
    Save-Powercfg 'sleepstudy' @('/sleepstudy', '/duration', '1', '/xml',
        '/output', (Join-Path $phaseDir 'sleepstudy.xml'))
    Save-Powercfg 'systempowerreport' @('/systempowerreport', '/duration', '1', '/xml',
        '/output', (Join-Path $phaseDir 'systempowerreport.xml'))
    Save-Powercfg 'batteryreport' @('/batteryreport', '/duration', '1', '/xml',
        '/output', (Join-Path $phaseDir 'batteryreport.xml'))
}

# For Before, this is the sample nearest the subsequent manual sleep action.
Save-Battery 'battery-last'
[ordered]@{
    Phase=$Phase; CompletedUtc=(Get-Date).ToUniversalTime().ToString('o')
    Errors=@($script:problems)
    Note='Collection finished; inspect Errors and raw reports. This is not a test pass marker.'
} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $phaseDir 'complete.json') -Encoding UTF8
Write-Host ('Reports: ' + $TrialDirectory)
if ($Phase -eq 'Before') {
    Write-Host 'Collection ended. Keep the same charger/port and manually select Sleep for 20 minutes.'
    Write-Host 'After waking, run Phase After with the TrialDirectory printed above.'
} else {
    Write-Host 'Review battery-first, sleepstudy and systempowerreport together; AC SleepStudy omits energy change.'
}
