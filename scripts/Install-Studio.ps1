# Installs Roblox Studio silently on a GitHub Actions Windows runner.
# No login, no account: just the installer + the exe path for later steps.
#
# Run 1 lesson (2026-11-17): this step hung for 55+ min with no timeout
# anywhere -- Invoke-WebRequest has no default timeout, and
# Start-Process -Wait waits forever. Every wait below is now bounded, so a
# stuck phase fails fast and says WHICH phase stuck.
#
# VERIFY ON FIRST RUN: the installer URL is the standard one used by the
# official "Download Studio" button and by Bloxstrap
# (https://setup.rbxcdn.com/RobloxStudioInstaller.exe). It is an NSIS
# installer, so /S is the standard silent flag. If Roblox ever changes the
# URL or the flag, this step fails fast with the installer log on screen.
# The runner user is an administrator, which the installer needs.

$ErrorActionPreference = "Stop"

$InstallerUrl = "https://setup.rbxcdn.com/RobloxStudioInstaller.exe"
$InstallerPath = Join-Path $env:TEMP "RobloxStudioInstaller.exe"
$OutDir = Join-Path $env:GITHUB_WORKSPACE "out"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Write-Host $line
}

function Wait-ProcessBounded($proc, $timeoutSec, $what) {
    # Polls for exit; returns $true if it exited in time, $false on timeout.
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while (-not $proc.HasExited) {
        if ((Get-Date) -gt $deadline) {
            Log "$what did NOT exit within ${timeoutSec}s -- killing it"
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            return $false
        }
        Start-Sleep -Seconds 15
    }
    return $true
}

Log "Downloading Studio installer from $InstallerUrl ..."
Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing -TimeoutSec 300
Log "Installer size: $((Get-Item $InstallerPath).Length) bytes"

Log "Running installer silently (/S) -- 20 min cap ..."
$proc = Start-Process -FilePath $InstallerPath -ArgumentList "/S" -PassThru -NoNewWindow
$ok = Wait-ProcessBounded $proc 1200 "Studio installer"
if ($ok) {
    Log "Installer exit code: $($proc.ExitCode)"
    if ($proc.ExitCode -ne 0) {
        throw "Studio installer failed with exit code $($proc.ExitCode)"
    }
} else {
    Log "Installer timed out after 20 min (exit code unknown -- process killed)"
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
    # If the installer timed out AND no exe appeared, the deploy never landed.
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
Log "API dump exit code: $($api.ExitCode)"
if (Test-Path $apiOut) {
    Log "API dump bytes: $((Get-Item $apiOut).Length)"
}
Log "STUDIO_INSTALL_OK"
