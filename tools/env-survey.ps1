#Requires -Version 5.1
<#
.SYNOPSIS
    Step 0 environment survey for the local-LLM screen overlay translator.

.DESCRIPTION
    Collects OS / display / hardware / local LLM runtime / dev tools / OCR
    information and benchmarks translation latency against the local LLM
    servers it finds. Writes everything to a Markdown report.

    The script is read-only: it installs nothing, changes no settings, and the
    only network traffic it generates goes to 127.0.0.1.

    Works in Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Only
    Run a single section: System, Llm, Dev or Ocr. Default: All.

.PARAMETER Models
    Model names to benchmark (e.g. qwen2.5:7b). Default: auto-select up to
    -MaxModels chat models, smallest first (models already loaded come first).

.PARAMETER SkipBenchmark
    Discover LLM servers and models but do not send translation requests.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\env-survey.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\env-survey.ps1 -Only Llm -Models qwen2.5:7b,gemma3:4b
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'System', 'Llm', 'Dev', 'Ocr')]
    [string]$Only = 'All',
    [string]$OutDir = (Get-Location).Path,
    [int[]]$Ports = @(11434, 1234, 8080, 5000, 8000, 5001, 1337),
    [string[]]$Models = @(),
    [int]$MaxModels = 4,
    [int]$WarmRuns = 3,
    [string]$TargetLanguage = 'Japanese',
    [switch]$SkipBenchmark
)

Set-StrictMode -Off
# "-File" passes "a,b" as one string; accept both forms.
$Models = @($Models | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:IsWin = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows
$script:Lines = New-Object System.Collections.Generic.List[string]
$script:Facts = New-Object System.Collections.Generic.List[object]
$script:Http = $null
$script:LlmFound = $null
$script:Started = Get-Date

# Test inputs for the translation benchmark (English -> $TargetLanguage).
$script:ShortText = 'Please review the attached document and let me know if you have any questions.'
$script:ParagraphText = 'Thank you for your quick reply. I have checked the schedule with the team, and we would like to move the project review meeting to Thursday afternoon at 3 PM. If that time does not work for you, please suggest two or three alternative slots next week. We will also send the updated agenda and the latest draft of the proposal by tomorrow morning, so you can review them in advance.'
$script:Sentences = @(
    'The server will be under maintenance from 10 PM to midnight.',
    'Click the Save button to apply your changes.',
    'Your order has been shipped and will arrive within three business days.'
)

#region ---------- report helpers ----------

function Add-Line([string]$Text = '') { $script:Lines.Add($Text) }

function Add-Heading([int]$Level, [string]$Text) {
    Add-Line ''
    Add-Line (('#' * $Level) + ' ' + $Text)
    Add-Line ''
    Write-Host ("==> " + $Text) -ForegroundColor Cyan
}

function Add-Code([string]$Text, [string]$Lang = 'text') {
    if ($null -eq $Text) { $Text = '' }
    Add-Line ('```' + $Lang)
    foreach ($l in (($Text -replace "`r", '') -split "`n")) { Add-Line $l }
    Add-Line '```'
}

function Add-Fact([string]$Item, $Value) {
    $script:Facts.Add([pscustomobject]@{ Item = $Item; Value = $Value })
}

function Format-Cell($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [array]) { $s = ($Value | ForEach-Object { "$_" }) -join ', ' } else { $s = "$Value" }
    return (($s -replace '\|', '\|') -replace "`r?`n", '<br>')
}

function Add-Table([object[]]$Rows, [string[]]$Columns) {
    $Rows = @($Rows | Where-Object { $null -ne $_ })
    if ($Rows.Count -eq 0) { Add-Line '_(none)_'; return }
    Add-Line ('| ' + ($Columns -join ' | ') + ' |')
    Add-Line ('|' + ((@($Columns | ForEach-Object { '---' })) -join '|') + '|')
    foreach ($r in $Rows) {
        $cells = foreach ($c in $Columns) { Format-Cell $r.$c }
        Add-Line ('| ' + ($cells -join ' | ') + ' |')
    }
}

function Limit-Text([string]$Text, [int]$Max = 200) {
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + '...'
}

function Get-InnerMessage([Exception]$Ex) {
    while ($Ex.InnerException) { $Ex = $Ex.InnerException }
    return $Ex.Message
}

function Get-Median([double[]]$Values) {
    $v = @($Values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    if ($v.Count % 2 -eq 1) { return $v[[int][Math]::Floor($v.Count / 2)] }
    return ($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2
}

function Format-Ms($Value) {
    if ($null -eq $Value) { return '-' }
    return ('{0:N0} ms' -f [double]$Value)
}

function Format-GB($Bytes) {
    if ($null -eq $Bytes -or [double]$Bytes -le 0) { return '' }
    return ('{0:N1} GB' -f ([double]$Bytes / 1GB))
}

function Invoke-Native {
    param([string]$File, [string]$Arguments = '', [int]$TimeoutSec = 60)
    $cmd = Get-Command $File -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $path = $cmd.Definition }
    elseif (Test-Path -LiteralPath $File -PathType Leaf) { $path = $File }
    else { return $null }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $path
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -1; Output = "(timed out after $TimeoutSec s)"; Path = $path }
        }
        $text = (@($outTask.Result, $errTask.Result) | Where-Object { $_ -and $_.Trim() }) -join "`n"
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = "$text".TrimEnd(); Path = $path }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = "(failed: $($_.Exception.Message))"; Path = $path }
    }
}

function Add-NativeOutput([string]$Title, [string]$File, [string]$Arguments = '', [int]$TimeoutSec = 60) {
    $r = Invoke-Native -File $File -Arguments $Arguments -TimeoutSec $TimeoutSec
    Add-Line ('**' + $Title + '** (`' + ($File + ' ' + $Arguments).Trim() + '`)')
    Add-Line ''
    if ($null -eq $r) { Add-Line '_not found_'; Add-Line ''; return $null }
    Add-Code $r.Output
    Add-Line ''
    return $r
}

function Get-EnvAll([string]$Name) {
    foreach ($scope in 'Process', 'User', 'Machine') {
        $v = [Environment]::GetEnvironmentVariable($Name, $scope)
        if ($v) { return "$v ($scope)" }
    }
    return $null
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

#endregion

#region ---------- HTTP helpers (localhost only) ----------

function Initialize-Http {
    if ($script:Http) { return }
    if ($PSVersionTable.PSEdition -ne 'Core') { Add-Type -AssemblyName System.Net.Http }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $script:Http = New-Object System.Net.Http.HttpClient -ArgumentList $handler
    $script:Http.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
}

function Invoke-Http {
    param([string]$Url, [string]$Method = 'GET', [string]$Body = $null, [int]$TimeoutSec = 3)
    $cts = New-Object System.Threading.CancellationTokenSource -ArgumentList ([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod -ArgumentList $Method), $Url
        if ($Body) { $req.Content = New-Object System.Net.Http.StringContent -ArgumentList $Body, ([System.Text.Encoding]::UTF8), 'application/json' }
        $resp = $script:Http.SendAsync($req, $cts.Token).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{ Ok = $resp.IsSuccessStatusCode; Status = [int]$resp.StatusCode; Body = $text; Error = $null }
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Body = $null; Error = (Get-InnerMessage $_.Exception) }
    } finally { $cts.Dispose() }
}

function ConvertFrom-JsonSafe([string]$Text) {
    if (-not $Text) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

function Format-ProbeResult($R, [string]$What = '') {
    if ($null -eq $R) { return '-' }
    if ($R.Status -eq 0) { return ('error: ' + (Limit-Text $R.Error 60)) }
    if ($What) { return "$($R.Status) ($What)" }
    return "$($R.Status)"
}

#endregion

#region ---------- System: OS, displays, hardware ----------

$script:MonitorProbeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class MonitorProbeInfo {
    public string Device; public bool Primary;
    public int Left; public int Top; public int Width; public int Height;
    public int WorkWidth; public int WorkHeight;
    public uint DpiX; public uint DpiY;
    public int ModeWidth; public int ModeHeight; public int Frequency; public int Bpp;
}

public static class MonitorProbe {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX {
        public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
        public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr hMonitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr ctx);

    public static string Awareness = "unknown";

    public static List<MonitorProbeInfo> Probe() {
        List<MonitorProbeInfo> list = new List<MonitorProbeInfo>();
        IntPtr prev = IntPtr.Zero;
        // Per-monitor-aware v2 so rectangles are physical pixels and DPI is real.
        try { prev = SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { }
        try {
            int a = GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext());
            Awareness = a == 2 ? "per-monitor" : (a == 1 ? "system" : (a == 0 ? "unaware" : a.ToString()));
        } catch (EntryPointNotFoundException) { }
        try {
            MonitorEnumProc cb = delegate (IntPtr h, IntPtr hdc, ref RECT r, IntPtr d) {
                MONITORINFOEX mi = new MONITORINFOEX();
                mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
                if (!GetMonitorInfo(h, ref mi)) return true;
                MonitorProbeInfo m = new MonitorProbeInfo();
                m.Device = mi.szDevice;
                m.Primary = (mi.dwFlags & 1) != 0;
                m.Left = mi.rcMonitor.Left; m.Top = mi.rcMonitor.Top;
                m.Width = mi.rcMonitor.Right - mi.rcMonitor.Left; m.Height = mi.rcMonitor.Bottom - mi.rcMonitor.Top;
                m.WorkWidth = mi.rcWork.Right - mi.rcWork.Left; m.WorkHeight = mi.rcWork.Bottom - mi.rcWork.Top;
                try {
                    uint dx, dy;
                    if (GetDpiForMonitor(h, 0, out dx, out dy) == 0) { m.DpiX = dx; m.DpiY = dy; }
                } catch (Exception) { }
                DEVMODE dm = new DEVMODE();
                dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
                if (EnumDisplaySettings(mi.szDevice, -1, ref dm)) {
                    m.ModeWidth = dm.dmPelsWidth; m.ModeHeight = dm.dmPelsHeight;
                    m.Frequency = dm.dmDisplayFrequency; m.Bpp = dm.dmBitsPerPel;
                }
                list.Add(m);
                return true;
            };
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
            GC.KeepAlive(cb);
        } finally {
            if (prev != IntPtr.Zero) { try { SetThreadDpiAwarenessContext(prev); } catch (Exception) { } }
        }
        return list;
    }
}
'@

function Invoke-SystemSection {
    Add-Heading 2 '1. OS and displays'
    if (-not $script:IsWin) { Add-Line '_Skipped: not running on Windows._'; return }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $build = [int]$os.BuildNumber
        $osRows = @(
            [pscustomobject]@{ Item = 'Product'; Value = $os.Caption }
            [pscustomobject]@{ Item = 'Edition ID'; Value = $cv.EditionID }
            [pscustomobject]@{ Item = 'Display version'; Value = $cv.DisplayVersion }
            [pscustomobject]@{ Item = 'Version / build'; Value = ("{0} (build {1}.{2})" -f $os.Version, $os.BuildNumber, $cv.UBR) }
            [pscustomobject]@{ Item = '[Environment]::OSVersion'; Value = [Environment]::OSVersion.VersionString }
            [pscustomobject]@{ Item = 'Architecture'; Value = $os.OSArchitecture }
            [pscustomobject]@{ Item = 'OS UI languages'; Value = @($os.MUILanguages) }
            [pscustomobject]@{ Item = 'User culture / UI culture'; Value = ("{0} / {1}" -f (Get-Culture).Name, (Get-UICulture).Name) }
            [pscustomobject]@{ Item = 'PowerShell'; Value = ("{0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition) }
            [pscustomobject]@{ Item = 'Running as admin'; Value = (Test-IsAdmin) }
        )
        Add-Table $osRows @('Item', 'Value')
        Add-Line ''
        $wda = if ($build -ge 19041) { 'yes (build >= 19041)' } else { 'NO (needs Windows 10 2004 / build 19041+)' }
        $wgcBorder = if ($build -ge 20348) { 'yes' } else { 'no (yellow capture border cannot be disabled)' }
        Add-Line ("- SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) supported: **{0}**" -f $wda)
        Add-Line ("- Windows.Graphics.Capture borderless (IsBorderRequired=false) supported: {0}" -f $wgcBorder)
        Add-Fact 'OS' ("{0} {1} (build {2}.{3})" -f $os.Caption, $cv.DisplayVersion, $os.BuildNumber, $cv.UBR)
        Add-Fact 'WDA_EXCLUDEFROMCAPTURE' $wda
    } catch { Add-Line ("_OS query failed: {0}_" -f $_.Exception.Message) }

    Add-Heading 3 'Displays'
    try {
        if (-not ('MonitorProbe' -as [type])) { Add-Type -TypeDefinition $script:MonitorProbeSource -Language CSharp }
        $mons = @([MonitorProbe]::Probe())
        $rows = foreach ($m in $mons) {
            $scale = if ($m.DpiX) { ('{0}%' -f [Math]::Round($m.DpiX / 96.0 * 100)) } else { '?' }
            [pscustomobject]@{
                Device        = $m.Device
                Primary       = $m.Primary
                'Mode (px)'   = ('{0}x{1} @{2}Hz' -f $m.ModeWidth, $m.ModeHeight, $m.Frequency)
                'Bounds (physical)' = ('{0},{1} {2}x{3}' -f $m.Left, $m.Top, $m.Width, $m.Height)
                'Work area'   = ('{0}x{1}' -f $m.WorkWidth, $m.WorkHeight)
                DPI           = $m.DpiX
                Scale         = $scale
            }
        }
        Add-Line ("Monitors: **{0}** (probe thread DPI awareness: {1})" -f $mons.Count, [MonitorProbe]::Awareness)
        Add-Line ''
        Add-Table $rows @('Device', 'Primary', 'Mode (px)', 'Bounds (physical)', 'Work area', 'DPI', 'Scale')
        Add-Fact 'Displays' (($rows | ForEach-Object { '{0} {1}{2}' -f $_.'Mode (px)', $_.Scale, $(if ($_.Primary) { ' (primary)' } else { '' }) }) -join '; ')
    } catch { Add-Line ("_Display probe failed: {0}_" -f (Get-InnerMessage $_.Exception)) }

    try {
        $names = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object {
            $dec = { param($a) if ($a) { -join ($a | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) } }
            '{0} {1}' -f (& $dec $_.ManufacturerName), (& $dec $_.UserFriendlyName)
        }
        if ($names) { Add-Line ''; Add-Line ('Monitor models (EDID): ' + (($names | ForEach-Object { $_.Trim() }) -join '; ')) }
    } catch { }
    try {
        $tsf = (Get-ItemProperty 'HKCU:\Software\Microsoft\Accessibility' -ErrorAction Stop).TextScaleFactor
        if ($tsf) { Add-Line ''; Add-Line ("Accessibility text size: {0}%" -f $tsf) }
    } catch { }

    Add-Heading 2 '2. CPU / RAM / GPU'
    try {
        $cpu = @(Get-CimInstance Win32_Processor)
        $cs = Get-CimInstance Win32_ComputerSystem
        $mem = @(Get-CimInstance Win32_PhysicalMemory)
        $hwRows = @()
        foreach ($c in $cpu) {
            $hwRows += [pscustomobject]@{ Item = 'CPU'; Value = ('{0} ({1} cores / {2} threads, max {3} MHz)' -f $c.Name.Trim(), $c.NumberOfCores, $c.NumberOfLogicalProcessors, $c.MaxClockSpeed) }
        }
        $speeds = @($mem | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } | Sort-Object -Unique)
        $hwRows += [pscustomobject]@{ Item = 'RAM'; Value = ('{0} ({1} module(s), {2} MT/s)' -f (Format-GB $cs.TotalPhysicalMemory), $mem.Count, ($speeds -join '/')) }
        $hwRows += [pscustomobject]@{ Item = 'Machine'; Value = ('{0} {1}' -f $cs.Manufacturer, $cs.Model) }
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($bat) { $hwRows += [pscustomobject]@{ Item = 'Battery'; Value = ('present (status {0}, {1}% charged) - laptop: GPU clocks may drop on battery' -f $bat.BatteryStatus, $bat.EstimatedChargeRemaining) } }
        Add-Table $hwRows @('Item', 'Value')
        Add-Fact 'CPU' (($cpu | ForEach-Object { $_.Name.Trim() }) -join '; ')
        Add-Fact 'RAM' (Format-GB $cs.TotalPhysicalMemory)
    } catch { Add-Line ("_CPU/RAM query failed: {0}_" -f $_.Exception.Message) }

    Add-Heading 3 'GPU'
    try {
        # Win32_VideoController.AdapterRAM is 32-bit (caps at 4 GB); the driver
        # registry key has the real 64-bit value.
        $regVram = @{}
        $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        Get-ChildItem $classKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DriverDesc) { return }
            $size = $p.'HardwareInformation.qwMemorySize'
            if (-not $size) {
                $raw = $p.'HardwareInformation.MemorySize'
                if ($raw -is [byte[]] -and $raw.Length -ge 8) { $size = [BitConverter]::ToUInt64($raw, 0) }
                elseif ($raw -is [byte[]] -and $raw.Length -ge 4) { $size = [BitConverter]::ToUInt32($raw, 0) }
                elseif ($raw) { $size = [uint64]$raw }
            }
            if ($size) { $regVram[$p.DriverDesc] = [uint64]$size }
        }
        $gpuRows = foreach ($g in @(Get-CimInstance Win32_VideoController)) {
            $vram = if ($regVram.ContainsKey($g.Name)) { $regVram[$g.Name] } else { $g.AdapterRAM }
            [pscustomobject]@{
                GPU = $g.Name
                'Dedicated VRAM' = (Format-GB $vram)
                Driver = $g.DriverVersion
                'Current mode' = $g.VideoModeDescription
            }
        }
        Add-Table @($gpuRows) @('GPU', 'Dedicated VRAM', 'Driver', 'Current mode')
        Add-Fact 'GPU' (($gpuRows | ForEach-Object { '{0} {1}' -f $_.GPU, $_.'Dedicated VRAM' }) -join '; ')
    } catch { Add-Line ("_GPU query failed: {0}_" -f $_.Exception.Message) }
    Add-Line ''
    $smi = Add-NativeOutput 'NVIDIA (query)' 'nvidia-smi' '--query-gpu=name,memory.total,memory.used,driver_version,utilization.gpu,pstate --format=csv'
    if ($smi) {
        [void](Add-NativeOutput 'NVIDIA (full)' 'nvidia-smi' '')
        Add-Fact 'nvidia-smi' ((($smi.Output -split "`n") | Select-Object -Skip 1) -join '; ')
    }
    try {
        $npu = @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='ComputeAccelerator'" -ErrorAction Stop)
        if ($npu.Count -gt 0) { Add-Line ('NPU / compute accelerators: ' + (($npu | ForEach-Object { $_.Name }) -join '; ')) }
    } catch { }
}

#endregion

#region ---------- LLM runtime discovery ----------

function Get-ListenInfo([int]$Port) {
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return '?' }
    try {
        $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Select-Object -First 1
        $pn = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        return ('yes ({0}, pid {1} {2})' -f $c.LocalAddress, $c.OwningProcess, $pn)
    } catch { return 'no' }
}

function Get-OllamaModelInfo([string]$BaseUrl, [string]$Name) {
    # /api/show can be several MB on older Ollama (tokenizer arrays) which
    # breaks ConvertFrom-Json on PS 5.1, so pull the fields out with regexes.
    $info = [ordered]@{ ContextMax = $null; NumCtx = $null; Capabilities = @() }
    $body = ConvertTo-Json -InputObject @{ model = $Name; name = $Name } -Compress
    $r = Invoke-Http -Url "$BaseUrl/api/show" -Method 'POST' -Body $body -TimeoutSec 15
    if (-not $r.Ok) { return [pscustomobject]$info }
    $m = [regex]::Match($r.Body, '"[A-Za-z0-9_\-]+\.context_length"\s*:\s*(\d+)')
    if ($m.Success) { $info.ContextMax = [int64]$m.Groups[1].Value }
    $m = [regex]::Match($r.Body, 'num_ctx\s+(\d+)')
    if ($m.Success) { $info.NumCtx = [int64]$m.Groups[1].Value }
    $m = [regex]::Match($r.Body, '"capabilities"\s*:\s*\[([^\]]*)\]')
    if ($m.Success) { $info.Capabilities = @([regex]::Matches($m.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) }
    return [pscustomobject]$info
}

function Test-EmbeddingModel([string]$Name, [string]$Family, $Capabilities, [string]$Type) {
    if ($Type -eq 'embeddings' -or $Type -eq 'embedding') { return $true }
    if ($Capabilities -and ($Capabilities -contains 'embedding') -and -not ($Capabilities -contains 'completion')) { return $true }
    if ($Family -match 'bert') { return $true }
    return ($Name -match 'embed|bge-|e5-|minilm|rerank')
}

function Find-LlmServers {
    $portList = New-Object System.Collections.Generic.List[int]
    foreach ($p in $Ports) { if (-not $portList.Contains($p)) { $portList.Add($p) } }
    $oh = Get-EnvAll 'OLLAMA_HOST'
    if ($oh -and $oh -match ':(\d+)') { $p = [int]$Matches[1]; if (-not $portList.Contains($p)) { $portList.Add($p) } }

    $servers = @()
    $probeRows = @()
    foreach ($port in $portList) {
        $base = "http://127.0.0.1:$port"
        $listen = Get-ListenInfo $port
        $row = [ordered]@{ Port = $port; Listening = $listen; '/api/tags' = '-'; '/v1/models' = '-'; '/api/v0/models' = '-'; '/props' = '-'; Detected = '' }
        if ($listen -eq 'no') { $probeRows += [pscustomobject]$row; continue }

        $tags = Invoke-Http -Url "$base/api/tags"
        if ($tags.Status -eq 0 -and $tags.Error -match 'refused|actively|No connection|Connection refused') {
            $row['/api/tags'] = 'refused'; $probeRows += [pscustomobject]$row; continue
        }
        $v1 = Invoke-Http -Url "$base/v1/models"
        $lms = Invoke-Http -Url "$base/api/v0/models"
        $props = Invoke-Http -Url "$base/props"

        $tagsJ = if ($tags.Ok) { ConvertFrom-JsonSafe $tags.Body } else { $null }
        $v1J = if ($v1.Ok) { ConvertFrom-JsonSafe $v1.Body } else { $null }
        $lmsJ = if ($lms.Ok) { ConvertFrom-JsonSafe $lms.Body } else { $null }
        $propsJ = if ($props.Ok) { ConvertFrom-JsonSafe $props.Body } else { $null }

        $row['/api/tags'] = Format-ProbeResult $tags $(if ($tagsJ -and $null -ne $tagsJ.models) { "$(@($tagsJ.models).Count) models" } else { '' })
        $row['/v1/models'] = Format-ProbeResult $v1 $(if ($v1J -and $null -ne $v1J.data) { "$(@($v1J.data).Count) models" } else { '' })
        $row['/api/v0/models'] = Format-ProbeResult $lms $(if ($lmsJ -and $null -ne $lmsJ.data) { "$(@($lmsJ.data).Count) models" } else { '' })
        $row['/props'] = Format-ProbeResult $props ''

        $server = $null
        if ($tagsJ -and $null -ne $tagsJ.models) {
            $ver = ConvertFrom-JsonSafe (Invoke-Http -Url "$base/api/version").Body
            $ps = ConvertFrom-JsonSafe (Invoke-Http -Url "$base/api/ps").Body
            $loaded = @{}
            if ($ps -and $ps.models) { foreach ($lm in $ps.models) { $loaded[$lm.name] = $lm } }
            $models = foreach ($m in @($tagsJ.models)) {
                $info = Get-OllamaModelInfo $base $m.name
                $ld = $loaded[$m.name]
                [pscustomobject]@{
                    Server = 'ollama'; BaseUrl = $base; Name = $m.name
                    Family = $m.details.family; Params = $m.details.parameter_size; Quant = $m.details.quantization_level
                    SizeBytes = [double]$m.size
                    ContextMax = $info.ContextMax
                    ContextRuntime = $(if ($ld -and $ld.context_length) { $ld.context_length } elseif ($info.NumCtx) { $info.NumCtx } else { $null })
                    Capabilities = $info.Capabilities
                    Loaded = [bool]$ld
                    IsEmbedding = (Test-EmbeddingModel $m.name $m.details.family $info.Capabilities '')
                }
            }
            $server = [pscustomobject]@{ Kind = 'ollama'; Port = $port; BaseUrl = $base; Version = $(if ($ver) { $ver.version } else { '' }); Models = @($models) }
        } elseif ($lmsJ -and $null -ne $lmsJ.data) {
            $models = foreach ($m in @($lmsJ.data)) {
                [pscustomobject]@{
                    Server = 'lmstudio'; BaseUrl = $base; Name = $m.id
                    Family = $m.arch; Params = ''; Quant = $m.quantization
                    SizeBytes = $null
                    ContextMax = $m.max_context_length
                    ContextRuntime = $m.loaded_context_length
                    Capabilities = @($m.type, $m.compatibility_type)
                    Loaded = ($m.state -eq 'loaded')
                    IsEmbedding = (Test-EmbeddingModel $m.id $m.arch $null $m.type)
                }
            }
            $server = [pscustomobject]@{ Kind = 'lmstudio'; Port = $port; BaseUrl = $base; Version = ''; Models = @($models) }
        } elseif ($propsJ -and ($propsJ.default_generation_settings -or $propsJ.model_path)) {
            $models = foreach ($m in @($v1J.data)) {
                [pscustomobject]@{
                    Server = 'llamacpp'; BaseUrl = $base; Name = $m.id
                    Family = ''; Params = $m.meta.n_params; Quant = (Split-Path -Leaf "$($propsJ.model_path)")
                    SizeBytes = $m.meta.size
                    ContextMax = $m.meta.n_ctx_train
                    ContextRuntime = $(if ($propsJ.default_generation_settings.n_ctx) { $propsJ.default_generation_settings.n_ctx } else { $propsJ.n_ctx })
                    Capabilities = @()
                    Loaded = $true
                    IsEmbedding = $false
                }
            }
            $server = [pscustomobject]@{ Kind = 'llamacpp'; Port = $port; BaseUrl = $base; Version = "$($propsJ.build_info)"; Models = @($models) }
        } elseif ($v1J -and $null -ne $v1J.data) {
            $models = foreach ($m in @($v1J.data)) {
                [pscustomobject]@{
                    Server = 'openai'; BaseUrl = $base; Name = $m.id
                    Family = $m.owned_by; Params = ''; Quant = ''; SizeBytes = $null
                    ContextMax = $null; ContextRuntime = $null; Capabilities = @()
                    Loaded = $true
                    IsEmbedding = (Test-EmbeddingModel $m.id '' $null '')
                }
            }
            $server = [pscustomobject]@{ Kind = 'openai-compatible'; Port = $port; BaseUrl = $base; Version = ''; Models = @($models) }
        }
        if ($server) { $row.Detected = ('{0} {1}' -f $server.Kind, $server.Version).Trim(); $servers += $server }
        $probeRows += [pscustomobject]$row
    }
    return [pscustomobject]@{ Servers = $servers; ProbeRows = $probeRows }
}

#endregion

#region ---------- LLM translation benchmark ----------

function Get-SystemPrompt {
    return "You are a translation engine. Translate the user's text into $TargetLanguage. Output only the translation. Do not add explanations, notes, quotation marks, or any preface."
}

function Get-VisibleText([string]$Raw) {
    # Hide <think>...</think> blocks that some reasoning models emit inline.
    if ($null -eq $Raw) { return '' }
    $idx = $Raw.LastIndexOf('</think>')
    if ($idx -ge 0) { return $Raw.Substring($idx + 8) }
    $trim = $Raw.TrimStart()
    if ($trim.StartsWith('<think>')) { return '' }
    if ($trim.Length -lt 7 -and '<think>'.StartsWith($trim)) { return '' }
    return $Raw
}

function New-ChatBody($Target, [string]$Text, $Think, [bool]$Stream) {
    $messages = @(
        @{ role = 'system'; content = (Get-SystemPrompt) },
        @{ role = 'user'; content = $Text }
    )
    if ($Target.Server -eq 'ollama') {
        $body = @{ model = $Target.Name; messages = $messages; stream = $Stream; keep_alive = '10m'; options = @{ temperature = 0 } }
        if ($null -ne $Think) { $body['think'] = [bool]$Think }
        $url = "$($Target.BaseUrl)/api/chat"
    } else {
        $body = @{ model = $Target.Name; messages = $messages; stream = $Stream; temperature = 0; max_tokens = 1024 }
        $url = "$($Target.BaseUrl)/v1/chat/completions"
    }
    return [pscustomobject]@{ Url = $url; Json = (ConvertTo-Json -InputObject $body -Depth 6 -Compress) }
}

function Invoke-ChatStream {
    param($Target, [string]$Text, $Think = $null, [int]$TimeoutSec = 300)
    $req = New-ChatBody $Target $Text $Think $true
    $err = $null; $ttftAny = $null; $ttft = $null; $total = $null
    $chunks = 0; $thinkChars = 0; $evalCount = $null; $evalTps = $null; $promptMs = $null; $loadMs = $null
    $raw = New-Object System.Text.StringBuilder
    $cts = New-Object System.Threading.CancellationTokenSource -ArgumentList ([TimeSpan]::FromSeconds($TimeoutSec))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $msg = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Post), $req.Url
        $msg.Content = New-Object System.Net.Http.StringContent -ArgumentList $req.Json, ([System.Text.Encoding]::UTF8), 'application/json'
        $resp = $script:Http.SendAsync($msg, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            $err = ('HTTP {0}: {1}' -f [int]$resp.StatusCode, (Limit-Text $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() 300))
        } else {
            $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $reader = New-Object System.IO.StreamReader -ArgumentList $stream, ([System.Text.Encoding]::UTF8)
            while ($null -ne ($line = $reader.ReadLine())) {
                $t = $sw.Elapsed.TotalMilliseconds
                if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { $err = 'timed out while streaming'; break }
                $line = $line.Trim()
                if (-not $line) { continue }
                $piece = ''; $thinkPiece = ''
                if ($Target.Server -eq 'ollama') {
                    $o = ConvertFrom-JsonSafe $line
                    if ($null -eq $o) { continue }
                    if ($o.error) { $err = "$($o.error)"; break }
                    if ($o.message) { $piece = "$($o.message.content)"; $thinkPiece = "$($o.message.thinking)" }
                    if ($o.done) {
                        if ($o.eval_count) { $evalCount = [int64]$o.eval_count }
                        if ($o.eval_duration -and $o.eval_count) { $evalTps = [double]$o.eval_count / ([double]$o.eval_duration / 1e9) }
                        if ($o.prompt_eval_duration) { $promptMs = [double]$o.prompt_eval_duration / 1e6 }
                        if ($o.load_duration) { $loadMs = [double]$o.load_duration / 1e6 }
                    }
                } else {
                    if (-not $line.StartsWith('data:')) { continue }
                    $payload = $line.Substring(5).Trim()
                    if ($payload -eq '[DONE]') { break }
                    $o = ConvertFrom-JsonSafe $payload
                    if ($null -eq $o) { continue }
                    if ($o.error) { $err = "$(if ($o.error.message) { $o.error.message } else { $o.error })"; break }
                    $choice = @($o.choices) | Select-Object -First 1
                    if ($choice -and $choice.delta) {
                        $piece = "$($choice.delta.content)"
                        $thinkPiece = "$($choice.delta.reasoning_content)$($choice.delta.reasoning)"
                    }
                    if ($o.usage -and $o.usage.completion_tokens) { $evalCount = [int64]$o.usage.completion_tokens }
                }
                if ($thinkPiece) {
                    $thinkChars += $thinkPiece.Length
                    if ($null -eq $ttftAny) { $ttftAny = $t }
                }
                if ($piece) {
                    $chunks++
                    if ($null -eq $ttftAny) { $ttftAny = $t }
                    [void]$raw.Append($piece)
                    if ($null -eq $ttft -and (Get-VisibleText $raw.ToString()).Trim()) { $ttft = $t }
                }
            }
            $reader.Dispose()
        }
    } catch {
        $err = Get-InnerMessage $_.Exception
    } finally {
        $total = $sw.Elapsed.TotalMilliseconds
        $cts.Dispose()
    }
    $all = $raw.ToString()
    $closeIdx = $all.LastIndexOf('</think>')
    if ($closeIdx -ge 0) { $thinkChars += $closeIdx }
    if ($null -eq $evalTps -and $chunks -gt 1 -and $null -ne $ttft -and $total -gt $ttft) {
        $n = if ($evalCount) { $evalCount } else { $chunks }
        $evalTps = ($n - 1) / (($total - $ttft) / 1000.0)
    }
    return [pscustomobject]@{
        Ok = (-not $err -and $null -ne $ttft); Error = $(if ($err) { $err } elseif ($null -eq $ttft) { 'empty response' } else { $null })
        TtftAnyMs = $ttftAny; TtftMs = $ttft; TotalMs = $total
        Output = (Get-VisibleText $all).Trim(); ThinkingChars = $thinkChars; Chunks = $chunks
        EvalCount = $evalCount; EvalTps = $evalTps; PromptMs = $promptMs; LoadMs = $loadMs
    }
}

function Invoke-ChatParallel {
    param($Target, [string[]]$Texts, $Think = $null, [int]$TimeoutSec = 300)
    $cts = New-Object System.Threading.CancellationTokenSource -ArgumentList ([TimeSpan]::FromSeconds($TimeoutSec))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $err = $null
    try {
        $tasks = foreach ($text in $Texts) {
            $req = New-ChatBody $Target $text $Think $false
            $msg = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Post), $req.Url
            $msg.Content = New-Object System.Net.Http.StringContent -ArgumentList $req.Json, ([System.Text.Encoding]::UTF8), 'application/json'
            $script:Http.SendAsync($msg, $cts.Token)
        }
        foreach ($task in @($tasks)) {
            $resp = $task.GetAwaiter().GetResult()
            [void]$resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode) { $err = "HTTP $([int]$resp.StatusCode)" }
        }
    } catch { $err = Get-InnerMessage $_.Exception } finally { $cts.Dispose() }
    return [pscustomobject]@{ WallMs = $sw.Elapsed.TotalMilliseconds; Error = $err }
}

function Get-OllamaOffload($Target) {
    $ps = ConvertFrom-JsonSafe (Invoke-Http -Url "$($Target.BaseUrl)/api/ps").Body
    if (-not $ps -or -not $ps.models) { return $null }
    $m = @($ps.models) | Where-Object { $_.name -eq $Target.Name } | Select-Object -First 1
    if (-not $m -or -not $m.size) { return $null }
    $gpu = [Math]::Round([double]$m.size_vram / [double]$m.size * 100)
    $ctx = if ($m.context_length) { ", ctx $($m.context_length)" } else { '' }
    return ('{0}% GPU ({1} in VRAM of {2}{3})' -f $gpu, (Format-GB $m.size_vram), (Format-GB $m.size), $ctx)
}

function Measure-Target($Target) {
    Write-Host ("    benchmarking {0} ({1})" -f $Target.Name, $Target.BaseUrl) -ForegroundColor Gray
    $notes = @()
    $wasLoaded = $Target.Loaded
    $cold = Invoke-ChatStream -Target $Target -Text $script:ShortText
    $r = [ordered]@{
        Model = $Target.Name; Server = $Target.Server; Quant = $Target.Quant
        'Cold total' = ''; 'Warm TTFT (median)' = ''; 'Warm total (median)' = ''
        'Paragraph TTFT' = ''; 'Paragraph total' = ''; 'tok/s' = ''
        'Parallel x3 vs sequential' = ''; Offload = ''; Notes = ''
        _Outputs = @(); _Warm = @()
    }
    if (-not $cold.Ok) {
        $r.Notes = 'FAILED: ' + (Limit-Text $cold.Error 200)
        return [pscustomobject]$r
    }
    $coldNote = if ($cold.LoadMs) { ' (load {0})' -f (Format-Ms $cold.LoadMs) } elseif ($wasLoaded) { ' (already loaded)' } else { '' }
    $r['Cold total'] = (Format-Ms $cold.TotalMs) + $coldNote

    $think = $null
    if ($cold.ThinkingChars -gt 0) {
        $notes += ('reasoning model: default run spent {0} chars thinking, first visible token at {1}' -f $cold.ThinkingChars, (Format-Ms $cold.TtftMs))
        if ($Target.Server -eq 'ollama') {
            $probe = Invoke-ChatStream -Target $Target -Text $script:ShortText -Think $false
            if ($probe.Ok -and $probe.ThinkingChars -eq 0) { $think = $false; $notes += 'measured below with think=false' }
            else { $notes += ('think=false did not help: {0}' -f $(if ($probe.Error) { $probe.Error } else { 'still thinking' })) }
        }
    }

    $warm = @(for ($i = 0; $i -lt $WarmRuns; $i++) { Invoke-ChatStream -Target $Target -Text $script:ShortText -Think $think })
    $okWarm = @($warm | Where-Object { $_.Ok })
    if ($okWarm.Count -gt 0) {
        $r['Warm TTFT (median)'] = Format-Ms (Get-Median ($okWarm | ForEach-Object { $_.TtftMs }))
        $r['Warm total (median)'] = Format-Ms (Get-Median ($okWarm | ForEach-Object { $_.TotalMs }))
        $r._Warm = $okWarm
    }
    if ($okWarm.Count -lt $warm.Count) { $notes += ('{0} warm run(s) failed: {1}' -f ($warm.Count - $okWarm.Count), ($warm | Where-Object { -not $_.Ok } | Select-Object -First 1).Error) }

    $para = Invoke-ChatStream -Target $Target -Text $script:ParagraphText -Think $think
    if ($para.Ok) {
        $r['Paragraph TTFT'] = Format-Ms $para.TtftMs
        $r['Paragraph total'] = Format-Ms $para.TotalMs
        if ($para.EvalTps) { $r['tok/s'] = ('{0:N1}{1}' -f $para.EvalTps, $(if ($Target.Server -eq 'ollama') { '' } else { ' (approx)' })) }
    } else { $notes += ('paragraph run failed: {0}' -f $para.Error) }

    $seq = @(foreach ($s in $script:Sentences) { Invoke-ChatStream -Target $Target -Text $s -Think $think })
    $par = Invoke-ChatParallel -Target $Target -Texts $script:Sentences -Think $think
    if (@($seq | Where-Object { -not $_.Ok }).Count -eq 0 -and -not $par.Error) {
        $seqSum = ($seq | Measure-Object -Property TotalMs -Sum).Sum
        $r['Parallel x3 vs sequential'] = ('{0} vs {1}' -f (Format-Ms $par.WallMs), (Format-Ms $seqSum))
    } elseif ($par.Error) { $notes += ('parallel run failed: {0}' -f $par.Error) }

    if ($Target.Server -eq 'ollama') { $r.Offload = Get-OllamaOffload $Target }
    $r.Notes = $notes -join '; '
    $r._Outputs = @(
        [pscustomobject]@{ Input = $script:ShortText; Output = $(if ($okWarm.Count) { $okWarm[0].Output } else { $cold.Output }) }
        [pscustomobject]@{ Input = $script:ParagraphText; Output = $para.Output }
    ) + @(for ($i = 0; $i -lt $seq.Count; $i++) { [pscustomobject]@{ Input = $script:Sentences[$i]; Output = $seq[$i].Output } })
    return [pscustomobject]$r
}

function Invoke-LlmSection {
    Add-Heading 2 '3. Local LLM runtimes'
    Initialize-Http

    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(ollama|ollama app|ollama_llama_server|LM Studio|lms|llama-server|llama_server|server|koboldcpp.*|Jan|text-generation-launcher|python)$' })
    if ($procs.Count) {
        Add-Line ('Related processes: ' + (($procs | Sort-Object ProcessName -Unique | ForEach-Object { '{0} (pid {1})' -f $_.ProcessName, $_.Id }) -join ', '))
        Add-Line ''
    }

    $envRows = foreach ($n in 'OLLAMA_HOST', 'OLLAMA_MODELS', 'OLLAMA_KEEP_ALIVE', 'OLLAMA_NUM_PARALLEL', 'OLLAMA_MAX_LOADED_MODELS', 'OLLAMA_CONTEXT_LENGTH', 'OLLAMA_FLASH_ATTENTION', 'OLLAMA_KV_CACHE_TYPE', 'CUDA_VISIBLE_DEVICES') {
        $v = Get-EnvAll $n
        if ($v) { [pscustomobject]@{ Variable = $n; Value = $v } }
    }
    Add-Line '**Environment variables**'
    Add-Line ''
    Add-Table @($envRows) @('Variable', 'Value')
    Add-Line ''

    $ol = Add-NativeOutput 'Ollama version' 'ollama' '--version'
    if ($ol) {
        [void](Add-NativeOutput 'Ollama models' 'ollama' 'list')
        [void](Add-NativeOutput 'Ollama loaded models' 'ollama' 'ps')
    }
    $lmsExe = @('lms', "$env:USERPROFILE\.lmstudio\bin\lms.exe", "$env:USERPROFILE\.cache\lm-studio\bin\lms.exe") |
        Where-Object { (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $_ -PathType Leaf -ErrorAction SilentlyContinue) } | Select-Object -First 1
    if ($lmsExe) {
        [void](Add-NativeOutput 'LM Studio models' $lmsExe 'ls')
        [void](Add-NativeOutput 'LM Studio loaded models' $lmsExe 'ps')
    } else { Add-Line '**LM Studio CLI (lms)**: _not found_'; Add-Line '' }

    Add-Heading 3 'Port probe (127.0.0.1)'
    $found = Find-LlmServers
    Add-Table @($found.ProbeRows) @('Port', 'Listening', '/api/tags', '/v1/models', '/api/v0/models', '/props', 'Detected')

    Add-Heading 3 'Models found'
    $allModels = @($found.Servers | ForEach-Object { $_.Models })
    $modelRows = foreach ($m in $allModels) {
        [pscustomobject]@{
            Server = ('{0}:{1}' -f $m.Server, ([uri]$m.BaseUrl).Port)
            Model = $m.Name; Family = $m.Family; Params = $m.Params; Quant = $m.Quant
            Size = (Format-GB $m.SizeBytes)
            'Ctx (model max)' = $m.ContextMax; 'Ctx (runtime)' = $m.ContextRuntime
            Loaded = $m.Loaded
            Type = $(if ($m.IsEmbedding) { 'embedding' } else { (@($m.Capabilities) -join ',') })
        }
    }
    Add-Table @($modelRows) @('Server', 'Model', 'Family', 'Params', 'Quant', 'Size', 'Ctx (model max)', 'Ctx (runtime)', 'Loaded', 'Type')
    Add-Fact 'LLM servers' $(if ($found.Servers) { ($found.Servers | ForEach-Object { ('{0} {1}' -f $_.Kind, $_.Version).Trim() + (' @{0} ({1} models)' -f $_.Port, @($_.Models).Count) }) -join '; ' } else { 'none found' })
    $script:LlmFound = $found
}

function Invoke-BenchmarkSection {
    Add-Heading 2 '6. Translation latency benchmark'
    Initialize-Http
    if (-not $script:LlmFound) { $script:LlmFound = Find-LlmServers }
    $found = $script:LlmFound
    $allModels = @($found.Servers | ForEach-Object { $_.Models })
    if ($SkipBenchmark) { Add-Line '_Skipped (-SkipBenchmark)._'; return }
    $chat = @($allModels | Where-Object { -not $_.IsEmbedding })
    if ($Models.Count -gt 0) {
        $targets = @(foreach ($n in $Models) {
            $hit = @($allModels | Where-Object { $_.Name -eq $n -or $_.Name -eq "$($n):latest" }) | Select-Object -First 1
            if ($hit) { $hit } else { Add-Line ('- requested model `{0}` not found on any server' -f $n) }
        })
    } else {
        $targets = @()
        foreach ($s in $found.Servers) {
            $sm = @($chat | Where-Object { $_.BaseUrl -eq $s.BaseUrl })
            if ($s.Kind -eq 'ollama') {
                $targets += @($sm | Sort-Object @{ Expression = { -not $_.Loaded } }, @{ Expression = { $_.SizeBytes } })
            } else {
                # JIT loading on LM Studio etc. can swap models; test loaded ones, else just the first.
                $l = @($sm | Where-Object { $_.Loaded })
                $targets += $(if ($l.Count) { $l } else { @($sm | Select-Object -First 1) })
            }
        }
        if ($targets.Count -gt $MaxModels) {
            Add-Line ('- Testing {0} of {1} chat models (smallest first). Skipped: {2}. Use `-Models name1,name2` to choose.' -f $MaxModels, $targets.Count, (($targets | Select-Object -Skip $MaxModels | ForEach-Object { $_.Name }) -join ', '))
            $targets = @($targets | Select-Object -First $MaxModels)
        }
    }
    if ($targets.Count -eq 0) { Add-Line '_No chat model available to benchmark._'; return }

    Add-Line ('- Direction: English -> {0}, temperature 0, streaming. System prompt: "{1}"' -f $TargetLanguage, (Get-SystemPrompt))
    Add-Line ('- Short input: {0} chars. Paragraph input: {1} chars. Warm runs: {2}.' -f $script:ShortText.Length, $script:ParagraphText.Length, $WarmRuns)
    Add-Line '- TTFT = time from sending the request to the first visible (non-thinking) output token, measured on the client.'
    Add-Line '- "Parallel x3" sends 3 different sentences at once; compare with the same 3 sent one after another.'
    Add-Line ''

    $results = @(foreach ($t in $targets) { Measure-Target $t })
    Add-Table $results @('Model', 'Server', 'Quant', 'Cold total', 'Warm TTFT (median)', 'Warm total (median)', 'Paragraph TTFT', 'Paragraph total', 'tok/s', 'Parallel x3 vs sequential', 'Offload', 'Notes')

    $best = $results | Where-Object { $_._Warm.Count -gt 0 } |
        Sort-Object { Get-Median ($_._Warm | ForEach-Object { $_.TtftMs }) } | Select-Object -First 1
    if ($best) { Add-Fact 'Fastest warm TTFT' ('{0}: TTFT {1}, total {2}' -f $best.Model, $best.'Warm TTFT (median)', $best.'Warm total (median)') }

    Add-Heading 3 'Translation outputs (for quality check)'
    foreach ($res in $results) {
        if (-not $res._Outputs) { continue }
        Add-Line ('**{0}**' -f $res.Model)
        Add-Line ''
        Add-Table $res._Outputs @('Input', 'Output')
        Add-Line ''
    }
}

#endregion

#region ---------- Dev tools ----------

function Invoke-DevSection {
    Add-Heading 2 '4. Development tools'
    $py = Add-NativeOutput 'Python launcher (all installs)' 'py' '-0p'
    if ($py) { Add-Fact 'Python (py -0p)' (($py.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join '; ') }
    $pyCmds = @(Get-Command python, python3 -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Definition })
    Add-Line ('`python` on PATH: ' + $(if ($pyCmds) { ($pyCmds -join '; ') } else { '_none_' }))
    Add-Line ''
    $pv = Add-NativeOutput 'python --version' 'python' '--version' 15
    if (-not $py -and $pv) { Add-Fact 'Python' $pv.Output }
    if ($py) { [void](Add-NativeOutput 'pip (default py)' 'py' '-m pip --version') }
    elseif ($pv) { [void](Add-NativeOutput 'pip' 'python' '-m pip --version') }

    $sdks = Add-NativeOutput '.NET SDKs' 'dotnet' '--list-sdks'
    [void](Add-NativeOutput '.NET runtimes' 'dotnet' '--list-runtimes')
    Add-Fact '.NET SDKs' $(if ($sdks -and $sdks.Output) { ($sdks.Output -split "`n" | ForEach-Object { ($_ -split ' ')[0] }) -join ', ' } else { 'none' })

    $node = Add-NativeOutput 'Node.js' 'node' '-v'
    [void](Add-NativeOutput 'npm' 'npm.cmd' '-v')
    $git = Add-NativeOutput 'Git' 'git' '--version'
    [void](Add-NativeOutput 'winget' 'winget' '--version')
    Add-Fact 'Node / Git' ('{0} / {1}' -f $(if ($node) { $node.Output } else { 'none' }), $(if ($git) { $git.Output } else { 'none' }))

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $vs = Invoke-Native $vswhere '-all -products * -format json'
        $vsJ = ConvertFrom-JsonSafe $vs.Output
        Add-Line '**Visual Studio / Build Tools**'
        Add-Line ''
        Add-Table @($vsJ | ForEach-Object { [pscustomobject]@{ Name = $_.displayName; Version = $_.installationVersion } }) @('Name', 'Version')
    } else { Add-Line '**Visual Studio / Build Tools**: _not found_' }
}

#endregion

#region ---------- OCR ----------

# Runs in Windows PowerShell 5.1 (WinRT projection is not available in PS 7).
$script:OcrScript = @'
param([string]$OutFile, [string]$WorkDir)
$ErrorActionPreference = 'Stop'
$result = [ordered]@{ Languages = @(); UserProfileLanguage = $null; MaxImageDimension = $null; Benchmarks = @(); Error = $null }
function J([int[]]$Codes) { -join ($Codes | ForEach-Object { [char]$_ }) }
try {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Foundation.IAsyncOperation`1, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $awaiter = [WindowsRuntimeSystemExtensions].GetMember('GetAwaiter', 'Method', 'Public,Static') |
        Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    function Await($Op, [Type]$T) { $awaiter.MakeGenericMethod($T).Invoke($null, @($Op)).GetResult() }

    $langs = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages)
    $result.Languages = @($langs | ForEach-Object { '{0} ({1})' -f $_.LanguageTag, $_.DisplayName })
    $result.MaxImageDimension = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
    $up = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($up) { $result.UserProfileLanguage = $up.RecognizerLanguage.LanguageTag }

    function New-TextImage([string]$Path, [string[]]$Lines, [string]$Font, [int]$Px, [int]$W) {
        $h = [int]($Lines.Count * $Px * 1.6 + 24)
        $bmp = New-Object System.Drawing.Bitmap $W, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $f = New-Object System.Drawing.Font $Font, $Px, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
        $y = 12
        foreach ($l in $Lines) { $g.DrawString($l, $f, [System.Drawing.Brushes]::Black, 12, $y); $y += [int]($Px * 1.6) }
        $g.Dispose(); $f.Dispose()
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $size = '{0}x{1}' -f $bmp.Width, $bmp.Height
        $bmp.Dispose()
        return $size
    }

    function Measure-Ocr([string]$Name, $Engine, [string]$Path, [string]$Size, [bool]$KeepText) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
        $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $decodeMs = $sw.Elapsed.TotalMilliseconds
        $times = @(); $text = ''
        for ($i = 0; $i -lt 6; $i++) {
            $sw.Restart()
            $r = Await ($Engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
            if ($i -gt 0) { $times += $sw.Elapsed.TotalMilliseconds } else { $first = $sw.Elapsed.TotalMilliseconds }
            $text = $r.Text
        }
        try { $stream.Dispose() } catch { }
        $sorted = @($times | Sort-Object)
        return [ordered]@{
            Case = $Name; Engine = $Engine.RecognizerLanguage.LanguageTag; Image = $Size
            DecodeMs = [Math]::Round($decodeMs, 1); FirstMs = [Math]::Round($first, 1)
            MedianMs = [Math]::Round($sorted[[int][Math]::Floor($sorted.Count / 2)], 1)
            Chars = $text.Length; Text = $(if ($KeepText) { $text } else { '' })
        }
    }

    $en = @($langs | Where-Object { $_.LanguageTag -like 'en*' }) | Select-Object -First 1
    $ja = @($langs | Where-Object { $_.LanguageTag -like 'ja*' }) | Select-Object -First 1

    $enLine = 'Please review the attached document and let me know if you have any questions.'
    $enPage = @(
        'Thank you for your quick reply. I have checked the schedule with the team, and we would like',
        'to move the project review meeting to Thursday afternoon at 3 PM. If that time does not work',
        'for you, please suggest two or three alternative slots next week. We will also send the updated',
        'agenda and the latest draft of the proposal by tomorrow morning, so you can review them in advance.'
    ) * 6
    # "The meeting has been moved to 3 PM tomorrow. Please check the materials in advance."
    $jaLine = (J @(0x4F1A,0x8B70,0x306F,0x660E,0x65E5,0x306E,0x5348,0x5F8C,0x0033,0x6642,0x306B,0x5909,0x66F4,0x3055,0x308C,0x307E,0x3057,0x305F,0x3002)) + (J @(0x8CC7,0x6599,0x3092,0x4E8B,0x524D,0x306B,0x3054,0x78BA,0x8A8D,0x304F,0x3060,0x3055,0x3044,0x3002))

    if ($en) {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($en)
        foreach ($px in 14, 18, 24) {
            $p = Join-Path $WorkDir "en-line-$px.png"
            $s = New-TextImage $p @($enLine) 'Segoe UI' $px 1100
            $result.Benchmarks += Measure-Ocr "English 1 line, ${px}px" $engine $p $s $true
        }
        $p = Join-Path $WorkDir 'en-page.png'
        $s = New-TextImage $p $enPage 'Segoe UI' 16 900
        $result.Benchmarks += Measure-Ocr 'English 24 lines, 16px (email-like page)' $engine $p $s $false
    }
    if ($ja) {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($ja)
        foreach ($px in 16, 24) {
            $p = Join-Path $WorkDir "ja-line-$px.png"
            $s = New-TextImage $p @($jaLine) 'Yu Gothic UI' $px 900
            $result.Benchmarks += Measure-Ocr "Japanese 1 line, ${px}px" $engine $p $s $true
        }
    }
} catch {
    $result.Error = $_.Exception.ToString()
}
$json = $result | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding $false))
'@

function Invoke-OcrSection {
    Add-Heading 2 '5. OCR'
    if (-not $script:IsWin) { Add-Line '_Skipped: not running on Windows._'; return }

    Add-Heading 3 'Windows OCR capabilities (Get-WindowsCapability)'
    if (Test-IsAdmin) {
        try {
            $caps = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { $_.Name -like '*OCR*' })
            Add-Table @($caps | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = "$($_.State)" } }) @('Name', 'State')
        } catch { Add-Line ("_Get-WindowsCapability failed: {0}_" -f $_.Exception.Message) }
    } else {
        Add-Line '_Needs an elevated (admin) PowerShell. The WinRT query below shows the OCR languages that are actually usable, which is what matters for the app. To list installable packs too, run this in an admin PowerShell:_'
        Add-Code "Get-WindowsCapability -Online | Where-Object Name -like '*OCR*' | Format-Table Name, State" 'powershell'
    }
    try {
        $ul = @(Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag })
        Add-Line ''
        Add-Line ('User language list: ' + ($ul -join ', '))
    } catch { }

    Add-Heading 3 'Windows.Media.Ocr (WinRT) languages and speed'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('ocr-survey-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $scriptPath = Join-Path $work 'ocr.ps1'
        $outFile = Join-Path $work 'ocr.json'
        [IO.File]::WriteAllText($scriptPath, $script:OcrScript, (New-Object System.Text.UTF8Encoding $true))
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $ocrArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutFile "{1}" -WorkDir "{2}"' -f $scriptPath, $outFile, $work
        $run = Invoke-Native $ps51 $ocrArgs 180
        if (-not (Test-Path -LiteralPath $outFile)) {
            Add-Line '_OCR probe produced no output._'
            if ($run) { Add-Code $run.Output }
        } else {
            $o = [IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            Add-Line ('- Available recognizer languages: **{0}**' -f $(if ($o.Languages) { (@($o.Languages) -join ', ') } else { 'none' }))
            Add-Line ('- User-profile engine language: {0}' -f $o.UserProfileLanguage)
            Add-Line ('- OcrEngine.MaxImageDimension: {0}' -f $o.MaxImageDimension)
            Add-Line ''
            if ($o.Error) { Add-Line '_OCR benchmark error:_'; Add-Code $o.Error }
            $rows = @($o.Benchmarks | ForEach-Object {
                [pscustomobject]@{
                    Case = $_.Case; Engine = $_.Engine; Image = $_.Image
                    'Decode' = Format-Ms $_.DecodeMs; 'OCR first' = Format-Ms $_.FirstMs; 'OCR median' = Format-Ms $_.MedianMs
                    Chars = $_.Chars; 'Recognized text' = $_.Text
                }
            })
            Add-Line 'Synthetic images rendered by the script (no screen content is captured). "OCR median" = median of 5 runs after the first.'
            Add-Line ''
            Add-Table $rows @('Case', 'Engine', 'Image', 'Decode', 'OCR first', 'OCR median', 'Chars', 'Recognized text')
            Add-Fact 'Windows OCR languages' $(if ($o.Languages) { (@($o.Languages) -join ', ') } else { 'none' })
            $page = $rows | Where-Object { $_.Case -like '*page*' } | Select-Object -First 1
            if ($page) { Add-Fact 'Windows OCR speed (24-line page)' $page.'OCR median' }
        }
    } catch {
        Add-Line ("_OCR probe failed: {0}_" -f $_.Exception.Message)
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    Add-Heading 3 'Tesseract'
    $tessCandidates = @('tesseract', "$env:ProgramFiles\Tesseract-OCR\tesseract.exe", "${env:ProgramFiles(x86)}\Tesseract-OCR\tesseract.exe", "$env:LOCALAPPDATA\Programs\Tesseract-OCR\tesseract.exe")
    $tess = $tessCandidates | Where-Object { (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $_ -PathType Leaf -ErrorAction SilentlyContinue) } | Select-Object -First 1
    if ($tess) {
        $tv = Add-NativeOutput 'Tesseract version' $tess '--version'
        [void](Add-NativeOutput 'Tesseract languages' $tess '--list-langs')
        Add-Fact 'Tesseract' (($tv.Output -split "`n")[0])
    } else {
        Add-Line '_not found_'
        Add-Fact 'Tesseract' 'not found'
    }
}

#endregion

#region ---------- main ----------

Write-Host 'Overlay translator - environment survey (read-only, localhost only)' -ForegroundColor Green
if ($Only -in 'All', 'System') { Invoke-SystemSection }
if ($Only -in 'All', 'Llm') { Invoke-LlmSection }
if ($Only -in 'All', 'Dev') { Invoke-DevSection }
if ($Only -in 'All', 'Ocr') { Invoke-OcrSection }
if ($Only -in 'All', 'Llm') { Invoke-BenchmarkSection }

$elapsed = (Get-Date) - $script:Started
$header = New-Object System.Collections.Generic.List[string]
$header.Add('# Environment survey report')
$header.Add('')
$header.Add(('Generated {0} by tools/env-survey.ps1 (sections: {1}, took {2:N0} s).' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $Only, $elapsed.TotalSeconds))
$header.Add('Review the report before sharing: paths may contain your user name.')
$header.Add('')
$header.Add('## Summary')
$header.Add('')
$saved = $script:Lines
$script:Lines = $header
Add-Table $script:Facts.ToArray() @('Item', 'Value')
$script:Lines = $saved

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$outPath = Join-Path $OutDir ('env-report-{0}.md' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$all = New-Object System.Collections.Generic.List[string]
$all.AddRange($header)
$all.AddRange($script:Lines)
[IO.File]::WriteAllLines($outPath, $all, (New-Object System.Text.UTF8Encoding $true))
Write-Host ''
Write-Host ('Report written to: {0}' -f $outPath) -ForegroundColor Green

#endregion
