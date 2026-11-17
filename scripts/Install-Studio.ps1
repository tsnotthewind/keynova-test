# Installs Roblox Studio silently on a GitHub Actions Windows runner.
# No login, no account: just the installer + the exe path for later steps.
#
# Run 1 lesson (2026-11-17): this step hung for 55+ min with no timeout
# anywhere -- Invoke-WebRequest has no default timeout, and
# Start-Process -Wait waits forever. Every wait below is now bounded.
#
# Run 3 lesson (2026-11-17): polling $proc.HasExited then reading
# $proc.ExitCode gives an EMPTY exit code on this runner (Start-Process
# -PassThru quirk). The fix: use $proc.WaitForExit(ms), which guarantees
# ExitCode is populated, and if the code is still unavailable, judge the
# install by whether the exe actually landed -- not by the exit code.
#
# VERIFY ON FIRST RUN: the installer URL is the standard one used by the
# official "Download Studio" button and by Bloxstrap
# (https://setup.rbxcdn.com/RobloxStudioInstaller.exe). It is an NSIS
# installer, so /S is the standard silent flag. If Roblox ever changes the
# URL or the flag, this step fails fast with the installer log on screen.
# The runner user is an administrator, which the installer needs.
#
# ASCII ONLY in this file: Windows PowerShell 5.1 reads BOM-less .ps1
# files as Windows-1252, and UTF-8 multi-byte chars (e.g. em-dash) broke
# the parse on run 2. Do not add any non-ASCII character.

$ErrorActionPreference = "Stop"

$InstallerUrl = "https://setup.rbxcdn.com/RobloxStudioInstaller.exe"
$InstallerPath = Join-Path $env:TEMP "RobloxStudioInstaller.exe"
$OutDir = Join-Path $env:GITHUB_WORKSPACE "out"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$PhaseLog = Join-Path $OutDir "install-log.txt"

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $PhaseLog -Value $line -Encoding utf8
}

function Wait-ProcessBounded($proc, $timeoutSec, $what) {
    # Returns $true if the process exited in time, $false on timeout.
    # WaitForExit(ms) is the reliable way: after it returns $true the
    # ExitCode property is populated.
    if ($proc.WaitForExit($timeoutSec * 1000)) {
        return $true
    }
    Log "$what did NOT exit within ${timeoutSec}s -- killing it"
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    return $false
}

Log "Downloading Studio installer from $InstallerUrl ..."
Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing -TimeoutSec 300
Log "Installer size: $((Get-Item $InstallerPath).Length) bytes"

Log "Running installer silently (/S) -- 20 min cap ..."
$proc = Start-Process -FilePath $InstallerPath -ArgumentList "/S" -PassThru -NoNewWindow
$ok = Wait-ProcessBounded $proc 1200 "Studio installer"
if ($ok) {
    $code = $proc.ExitCode
    if ($null -eq $code) {
        Log "Installer exit code unavailable (Start-Process quirk) -- judging by whether the deploy landed"
    } elseif ($code -ne 0) {
        throw "Studio installer failed with exit code $code"
    } else {
        Log "Installer exit code: 0"
    }
} else {
    Log "Installer timed out after 20 min (process killed) -- judging by whether the deploy landed"
}

# The installer deploys into %LOCALAPPDATA%\Roblox\Versions\version-*\.
# Poll for the exe (first launch also downloads packages, so allow time).
Log "Looking for RobloxStudioBeta.exe under %LOCALAPPDATA%\Roblox\Versions ..."
$StudioExe = $null
for ($i = 0; $i -lt 60; $i++) {
    $StudioExe = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Roblox\Versions") `
        -Filter "RobloxStudioBeta.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($StudioExe) { break }
    if ($i % 12 -eq 11) { Log "  still waiting for exe ($((($i + 1) * 5))s) ..." }
    Start-Sleep -Seconds 5
}
if (-not $StudioExe) {
    # The deploy never landed: list what IS under %LOCALAPPDATA%\Roblox
    # so the failure is diagnosable from the log alone.
    Get-ChildItem (Join-Path $env:LOCALAPPDATA "Roblox") -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 20 FullName | ForEach-Object { Log "  found: $($_.FullName)" }
    throw "RobloxStudioBeta.exe not found under %LOCALAPPDATA%\Roblox\Versions after install"
}
Log "Studio exe: $StudioExe"
$StudioExe | Out-File (Join-Path $OutDir "studio-exe.txt") -Encoding utf8

# Sanity: the exe must at least start enough to dump its API (proves the
# deploy is intact without opening any window or needing a login).
# --api writes JSON and exits; if the deploy is broken this fails fast.
$apiOut = Join-Path $OutDir "studio-api.json"
Log "Probing deploy with --api (3 min cap) ..."
$api = Start-Process -FilePath $StudioExe -ArgumentList "--api", "`"$apiOut`"" `
    -PassThru -NoNewWindow
$apiOk = Wait-ProcessBounded $api 180 "--api probe"
if (-not $apiOk) {
    throw "--api probe did not exit within 180s -- deploy is broken or hung"
}
$apiCode = $api.ExitCode
Log "API dump exit code: $apiCode"
if (Test-Path $apiOut) {
    Log "API dump bytes: $((Get-Item $apiOut).Length)"
}
Log "STUDIO_INSTALL_OK"
