#requires -Version 5.1
<#
.SYNOPSIS
    Finds which background service (if any) causes a window/shell misbehaviour,
    without rebooting and without bisecting by hand.

.DESCRIPTION
    Replaces "clean boot" runs with an automated delta-debug loop:

      1. stop every non-core service, check the symptom
         -> still there?  the service set is not involved, everything is restarted
      2. otherwise binary-search the service list: start half of the remaining
         candidates, check, keep the half that reproduces the symptom
      3. report the single service that must be running for the bug to appear

    Core services (RPC, DCOM, audio, Defender, networking, ...) are never
    stopped; they are excluded up front.  The -Probe scriptblock receives no
    arguments and must return $true when the symptom is present.

.PARAMETER Probe
    Scriptblock returning $true when the problem reproduces.
    Default: opens a folder and reports "redirected to Desktop".

.PARAMETER Exclude
    Extra service names to never touch.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-ServiceBisect.ps1

.NOTES
    Running services are saved and restarted in a finally block, even on Ctrl+C.
    Anything that must stay up (VPN, license servers, sync clients) should be
    added with -Exclude, because stopping it may log you out of that service.
#>
[CmdletBinding()]
param(
    [scriptblock]$Probe,
    [string[]]$Exclude = @()
)

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Administrator rights required.' -ForegroundColor Red
    return
}

# vendor-neutral deny list: anything Windows needs to keep the session alive
$corePatterns = @(
    '^Rpc', '^DcomLaunch', '^PlugPlay', '^Power$', '^BrokerInfrastructure', '^SystemEventsBroker',
    '^SamSs', '^LSM', '^Winmgmt', '^EventLog', '^Schedule', '^Themes', '^AudioSrv', '^Audiosrv',
    '^AudioEndpointBuilder', '^CryptSvc', '^TrustedInstaller', '^WinDefend', '^SecurityHealthService',
    '^WdNisSvc', '^Sense', '^mpssvc', '^BFE', '^Dhcp', '^Dnscache', '^NlaSvc', '^netprofm', '^nsi',
    '^LanmanWorkstation', '^LanmanServer', '^lmhosts', '^Wcmsvc', '^ProfSvc', '^UserManager',
    '^StateRepository', '^TextInputManagementService', '^CDPSvc', '^camsvc', '^CoreMessagingRegistrar',
    '^DsmSvc', '^DeviceInstall', '^DeviceAssociationService', '^TimeBrokerSvc', '^ShellHWDetection',
    '^Spooler', '^WpnService', '^WpnUserService', '^TokenBroker', '^PcaSvc', '^SENS', '^SysMain',
    '^gpsvc', '^seclogon', '^W32Time', '^WerSvc', '^DPS', '^DiagTrack', '^UsoSvc', '^wuauserv',
    '^BITS', '^DoSvc', '^ClipSVC', '^LicenseManager', '^AppXSvc', '^StateRepository', '^WSearch',
    '^DisplayEnhancementService', '^GraphicsPerfSvc', '^psmsservice', '^WlanSvc', '^WwanSvc',
    '^TapiSrv', '^PhoneSvc', '^SstpSvc', '^RemoteAccess', '^IKEEXT', '^PolicyAgent', '^NcaSvc'
)

function Get-Candidates {
    $running = @(Get-Service | Where-Object { $_.Status -eq 'Running' })
    $cands = @()
    foreach ($s in $running) {
        if ($Exclude -contains $s.Name) { continue }
        $isCore = $false
        foreach ($p in $corePatterns) { if ($s.Name -match $p) { $isCore = $true; break } }
        if ($isCore) { continue }

        # skip services whose binary lives under Windows itself
        $path = $null
        try { $path = (Get-CimInstance Win32_Service -Filter ("Name='" + $s.Name + "'") -ErrorAction Stop).PathName } catch { }
        if ($path) {
            $exe = $path.Trim()
            if ($exe.StartsWith('"')) { $exe = $exe.Split('"')[1] } else { $exe = ($exe -split ' ')[0] }
            if ($exe -like "$env:SystemRoot\*") { continue }
        }
        $cands += $s.Name
    }
    return $cands
}

function Test-DefaultProbe {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject Shell.Application
    $before = @()
    foreach ($w in @($shell.Windows())) { $before += [int64]$w.HWND }

    Start-Process -FilePath 'explorer.exe' -ArgumentList '"C:\Windows"'
    Start-Sleep -Seconds 7

    $new = @($shell.Windows() | Where-Object { $before -notcontains [int64]$_.HWND })
    $bounced = $false
    foreach ($w in $new) {
        $url = [string]$w.LocationURL
        if ($url -match '/Desktop/?$') { $bounced = $true }
        try { $w.Quit() } catch { }
    }
    return $bounced
}

if (-not $Probe) { $Probe = ${function:Test-DefaultProbe} }

$candidates = Get-Candidates
if ($candidates.Count -eq 0) {
    Write-Host 'No non-core services found - nothing to bisect.' -ForegroundColor Yellow
    return
}
Write-Host ''
Write-Host ("=== Service bisect: " + $candidates.Count + " candidate service(s) ===") -ForegroundColor Cyan
Write-Host ("  " + ($candidates -join ', ')) -ForegroundColor DarkGray

$originallyRunning = @($candidates | Where-Object { (Get-Service $_).Status -eq 'Running' })

function Invoke-Probe {
    try { return [bool](& $Probe) } catch { Write-Host ("  probe error: " + $_.Exception.Message) -ForegroundColor Red; return $false }
}

function Stop-Candidates {
    foreach ($n in $candidates) {
        $svc = Get-Service $n -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { Stop-Service $n -Force -ErrorAction SilentlyContinue }
    }
}

function Start-Set([string[]]$names) {
    foreach ($n in $names) {
        try { Start-Service $n -ErrorAction Stop } catch { Write-Host ("  could not start $n") -ForegroundColor DarkGray }
    }
    Start-Sleep -Seconds 5
}

try {
    Write-Host ''
    Write-Host 'Phase 1: stop everything, does the symptom survive?'
    Stop-Candidates
    Start-Sleep -Seconds 4
    if (Invoke-Probe) {
        Write-Host ''
        Write-Host 'RESULT: every non-core service stopped, symptom still present.' -ForegroundColor Green
        Write-Host '        -> the cause is not a background service.' -ForegroundColor Green
        return
    }
    Write-Host ''
    Write-Host '  symptom gone with all candidates stopped -> one of them is involved.' -ForegroundColor Yellow

    Write-Host ''
    Write-Host 'Phase 2: binary search'
    $pool = @($candidates)
    $round = 0
    while ($pool.Count -gt 1) {
        $round++
        $half = [int][math]::Ceiling($pool.Count / 2)
        $left = @($pool[0..($half - 1)])
        $right = @($pool[$half..($pool.Count - 1)])

        Stop-Candidates
        Start-Sleep -Seconds 3
        Start-Set $left
        $hit = Invoke-Probe

        Write-Host ("  round {0}: started {1} service(s) -> {2}" -f $round, $left.Count,
            $(if ($hit) { 'reproduces' } else { 'clean' }))
        if ($hit) { $pool = $left } else { $pool = $right }
    }

    Write-Host ''
    Write-Host ("SUSPECT SERVICE: " + $pool[0]) -ForegroundColor Yellow
    Write-Host '  verify: stop it alone, then re-run the probe.' -ForegroundColor DarkGray
} finally {
    Write-Host ''
    Write-Host 'Restoring services that were running before the test ...' -ForegroundColor Cyan
    foreach ($n in $originallyRunning) {
        $svc = Get-Service $n -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            try { Start-Service $n -ErrorAction Stop } catch { Write-Host ("  failed to restart $n") -ForegroundColor Red }
        }
    }
    Write-Host '  done.'
}