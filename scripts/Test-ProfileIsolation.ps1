#requires -Version 5.1
<#
.SYNOPSIS
    One-minute triage: is a shell / window problem machine-wide or specific to
    the current user profile?

.DESCRIPTION
    Creates a throwaway local administrator account.  Log in with it and try to
    reproduce the problem:

      * reproduces in the clean account  -> machine-wide
        (system files, drivers, services, globally installed software)
      * clean account is fine            -> user profile only
        (HKCU state, profile files, per-user apps)

    That single test replaces hours of guessing and decides which repair path is
    worth pursuing at all.

.PARAMETER Name
    Account name, default 'dshprobe'.

.PARAMETER Password
    Account password, default 'Probe#<random>'.

.PARAMETER Remove
    Delete the probe account and its profile folder.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-ProfileIsolation.ps1

.EXAMPLE
    .\Test-ProfileIsolation.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$Name = 'dshprobe',
    [string]$Password,
    [switch]$Remove
)

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Elevation required - confirming UAC ...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Name', $Name)
    if ($Remove) { $argList += '-Remove' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

Write-Host ''

if ($Remove) {
    Write-Host ("=== Removing probe account '$Name' ===" -f $Name) -ForegroundColor Cyan
    $user = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if ($user) {
        $profile = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPath -like "*\$Name" }
        Remove-LocalUser -Name $Name -ErrorAction SilentlyContinue
        if ($profile) { Remove-CimInstance -InputObject $profile -ErrorAction SilentlyContinue }
        Write-Host '  account and profile removed.'
    } else {
        Write-Host '  account not found - nothing to do.'
    }
    Write-Host ''
    Write-Host 'Sign out / restart if the account still shows on the login screen.' -ForegroundColor DarkGray
    return
}

if (-not $Password) { $Password = 'Probe#' + (Get-Random -Minimum 100000 -Maximum 999999) }

if (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) {
    Write-Host ("Account '$Name' already exists - reusing it.") -ForegroundColor Yellow
    Set-LocalUser -Name $Name -Password (ConvertTo-SecureString $Password -AsPlainText -Force) -ErrorAction SilentlyContinue
} else {
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    New-LocalUser -Name $Name -Password $secure -FullName 'Shell triage probe' -Description 'Temporary account created by Test-ProfileIsolation.ps1' -ErrorAction Stop | Out-Null
    Add-LocalGroupMember -Group 'Administrators' -Member $Name -ErrorAction SilentlyContinue
    Write-Host ("Created local administrator '$Name'.") -ForegroundColor Green
}

Write-Host ''
Write-Host '  ------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ("   account : $Name")
Write-Host ("   password: $Password")
Write-Host '  ------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Next steps:'
Write-Host '    1. Win+L, switch to that account, log in (first login takes a minute)'
Write-Host '    2. Reproduce the problem there (open a folder window, etc.)'
Write-Host '    3. Note the result, switch back'
Write-Host '    4. Delete the account:  Test-ProfileIsolation.ps1 -Remove'
Write-Host ''
Write-Host '  Interpretation:' -ForegroundColor Yellow
Write-Host '    problem reproduces -> machine-wide  (system / drivers / services)'
Write-Host '    problem is gone    -> user profile  (HKCU state / profile files)'