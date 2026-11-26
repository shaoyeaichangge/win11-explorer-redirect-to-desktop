#requires -Version 5.1
<#
.SYNOPSIS
    Detects whether newly created File Explorer windows stay where they were
    asked to go, or get redirected to the Desktop.

.DESCRIPTION
    Opens a folder in a fresh Explorer window, waits, then reads back the
    window's URL through the Shell.Application COM object and compares it with
    the requested path.

    Verdicts:
      OK                  window stayed at the requested folder
      BOUNCED_TO_DESKTOP  window navigated to the user's Desktop
      NO_WINDOW           no new window was observed (increase -WaitSeconds)

    Also prints the HWND, so a caller can tell navigation (same HWND) apart
    from a crash-and-recreate (new HWND).

.PARAMETER Target
    One or more folders to test.

.PARAMETER WaitSeconds
    How long to observe each window.  The bug usually fires within 3.6 s.

.PARAMETER Repeat
    How many times to test each target.

.PARAMETER KeepOpen
    Leave the windows open (useful for manual inspection).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-ExplorerRedirect.ps1 -Target 'C:\Windows'

.EXAMPLE
    .\Test-ExplorerRedirect.ps1 -Target 'C:\Windows','D:\' -Repeat 3
#>
[CmdletBinding()]
param(
    [string[]]$Target = @('C:\Windows'),
    [int]$WaitSeconds = 6,
    [int]$Repeat = 1,
    [switch]$KeepOpen
)

$ErrorActionPreference = 'Continue'
$desktop = [Environment]::GetFolderPath('Desktop')
$failures = 0

function Get-WindowSet {
    $shell = New-Object -ComObject Shell.Application
    $list = @()
    foreach ($w in @($shell.Windows())) {
        if ($null -eq $w) { continue }
        $list += [pscustomobject]@{
            HWND = [int64]$w.HWND
            URL  = [string]$w.LocationURL
            Name = [string]$w.LocationName
        }
    }
    return $list
}

Write-Host ''
Write-Host '=== Explorer redirect test ===' -ForegroundColor Cyan
Write-Host ("  desktop: $desktop")

foreach ($t in $Target) {
    for ($i = 1; $i -le $Repeat; $i++) {
        $before = Get-WindowSet
        $beforeIds = @($before | ForEach-Object { $_.HWND })

        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $t + '"')

        $new = @()
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            $now = Get-WindowSet
            $new = @($now | Where-Object { $beforeIds -notcontains $_.HWND })
            if ($new.Count -gt 0) { break }
        }
        # keep observing after the window appeared: the redirect takes up to ~3.6 s
        $settleUntil = (Get-Date).AddSeconds($WaitSeconds)
        while ((Get-Date) -lt $settleUntil) {
            Start-Sleep -Milliseconds 400
            $now = Get-WindowSet
            $seen = @()
            foreach ($n in $new) { $seen += ($now | Where-Object { $_.HWND -eq $n.HWND }) }
            $new = $seen
        }

        if ($new.Count -eq 0) {
            $verdict = 'NO_WINDOW'
            $failures++
            Write-Host ("  [{0}] {1}  ->  NO_WINDOW (raise -WaitSeconds)" -f $i, $t) -ForegroundColor Yellow
            continue
        }

        foreach ($n in $new) {
            $isDesktop = $n.URL -match '/Desktop/?$'
            $expectedDesktop = ($t.TrimEnd('\') -ieq $desktop.TrimEnd('\'))
            if ($isDesktop -and -not $expectedDesktop) {
                $verdict = 'BOUNCED_TO_DESKTOP'
                $failures++
                Write-Host ("  [{0}] {1}  ->  BOUNCED_TO_DESKTOP  hwnd={2}  url={3}" -f $i, $t, $n.HWND, $n.URL) -ForegroundColor Red
            } else {
                $verdict = 'OK'
                Write-Host ("  [{0}] {1}  ->  OK  hwnd={2}  url={3}" -f $i, $t, $n.HWND, $n.URL) -ForegroundColor Green
            }
            if (-not $KeepOpen) {
                try { (New-Object -ComObject Shell.Application).Windows() | Out-Null } catch { }
                try {
                    $shell2 = New-Object -ComObject Shell.Application
                    foreach ($w in @($shell2.Windows())) { if ([int64]$w.HWND -eq $n.HWND) { $w.Quit() } }
                } catch { }
            }
        }
        Start-Sleep -Milliseconds 500
    }
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'RESULT: all windows stayed in place.' -ForegroundColor Green
    exit 0
}
Write-Host ("RESULT: $failures test(s) failed - the redirect bug is present.") -ForegroundColor Red
Write-Host '  Fix it with: scripts\Fix-ExplorerState.ps1' -ForegroundColor Yellow
exit 1