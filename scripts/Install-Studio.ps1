# Installs Roblox Studio silently on a GitHub Actions Windows runner.
# No login, no account: just the installer + the exe path for later steps.
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

Write-Host "Downloading Studio installer from $InstallerUrl ..."
Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing
Write-Host "Installer size: $((Get-Item $InstallerPath).Length) bytes"

Write-Host "Running installer silently (/S) ..."
$proc = Start-Process -FilePath $InstallerPath -ArgumentList "/S" -Wait -PassThru -NoNewWindow
Write-Host "Installer exit code: $($proc.ExitCode)"
if ($proc.ExitCode -ne 0) {
    throw "Studio installer failed with exit code $($proc.ExitCode)"
}

# The installer deploys into %LOCALAPPDATA%\Roblox\Versions\version-*\.
# Poll for the exe (first launch also downloads packages, so allow time).
$StudioExe = $null
for ($i = 0; $i -lt 60; $i++) {
    $StudioExe = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "Roblox\Versions") `
        -Filter "RobloxStudioBeta.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($StudioExe) { break }
    Start-Sleep -Seconds 5
}
if (-not $StudioExe) {
    throw "RobloxStudioBeta.exe not found under %LOCALAPPDATA%\Roblox\Versions after install"
}
Write-Host "Studio exe: $StudioExe"
$StudioExe | Out-File (Join-Path $OutDir "studio-exe.txt") -Encoding utf8

# Sanity: the exe must at least start enough to dump its API (proves the
# deploy is intact without opening any window or needing a login).
# --api writes JSON and exits; if the deploy is broken this fails fast.
$apiOut = Join-Path $OutDir "studio-api.json"
$api = Start-Process -FilePath $StudioExe -ArgumentList "--api", "`"$apiOut`"" `
    -Wait -PassThru -NoNewWindow
Write-Host "API dump exit code: $($api.ExitCode)"
if (Test-Path $apiOut) {
    Write-Host "API dump bytes: $((Get-Item $apiOut).Length)"
}
Write-Host "STUDIO_INSTALL_OK"
