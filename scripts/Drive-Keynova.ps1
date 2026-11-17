# Drives the headed Keynova test on a GitHub Actions Windows runner.
#
# What it does, in order:
#   1. Starts ffmpeg gdigrab recording the whole desktop (30 fps).
#   2. Opens test-place.rbxlx in Roblox Studio (headed, maximised).
#   3. GO / NO-GO CHECK: if Studio is sitting on a login screen, it writes
#      LOGIN_REQUIRED.txt, uploads the screenshot, and stops. No login is
#      attempted here -- that needs a decision (see PLAN.md).
#   4. Opens the Keynova plugin (Plugins tab -> Keynova button), loads the
#      pre-built "keynova-test-scene" save, presses Play, records 5 s.
#   5. Trims the 5 s clip out of the session recording, verifies it with
#      ffprobe, and writes RESULT.md.
#
# HOW CLICKS WORK (read this before run 1):
#   The script first tries Windows UI Automation (find a control by its
#   visible name and click its centre). Studio is a Qt app, so UIA may not
#   see every button -- if a lookup fails it falls back to the coordinate
#   table in $Clicks below. Those coordinates are PLACEHOLDERS measured
#   from a standard 1024x768 Studio layout and MUST be corrected from the
#   run-1 screenshots if they miss. Every step screenshots first, so a
#   miss is visible in the artifacts instead of silent.
#   Run 1 is a PROBE: expect to calibrate, not to get the video first try.
#
# Exit codes: 0 = video produced and verified; 2 = stopped at login screen;
# 3 = Studio never opened; 4 = Keynova UI not drivable (see screenshots).

param(
    [string]$PlacePath = (Join-Path $env:GITHUB_WORKSPACE "test-place.rbxlx"),
    [string]$OutDir = (Join-Path $env:GITHUB_WORKSPACE "out")
)
$ErrorActionPreference = "Continue"  # we handle failures step by step
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$LogFile = Join-Path $OutDir "driver.log"
function Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}
# Coordinate fallback table -- CALIBRATE from run-1 screenshots (1024x768).
$Clicks = @{
    PluginsTab    = @{ X = 330; Y = 42 }   # "Plugins" in the top ribbon
    KeynovaButton = @{ X = 120; Y = 110 }  # Keynova toolbar button (guess)
    SaveEntry     = @{ X = 200; Y = 300 }  # "keynova-test-scene" in Keynova list
    PlayButton    = @{ X = 200; Y = 120 }  # Play in the Keynova dock (guess)
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
    public const uint LEFTDOWN = 0x02, LEFTUP = 0x04, KEYUP = 0x02;
    public static void Click(int x, int y) {
        SetCursorPos(x, y); System.Threading.Thread.Sleep(120);
        mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
    }
    public static void PressSpace() {
        keybd_event(0x20, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(80);
        keybd_event(0x20, 0, KEYUP, UIntPtr.Zero);
    }
}
"@

function Shot($name) {
    $path = Join-Path $OutDir ("shot-" + $name + ".png")
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Log "screenshot: $path"
    return $path
}
Add-Type -AssemblyName System.Windows.Forms

function Click-UIA($root, $name) {
    # Find a control by visible name under $root (a window element) and click it.
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, $name)
        $el = $root.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants, $cond)
        if (-not $el) { return $false }
        $pt = $el.GetClickablePoint()
        [Win32]::Click([int]$pt.X, [int]$pt.Y)
        Log "UIA click '$name' at $([int]$pt.X),$([int]$pt.Y)"
        return $true
    } catch { Log "UIA click '$name' failed: $($_.Exception.Message)"; return $false }
}
function Click-At($key) {
    $c = $Clicks[$key]
    [Win32]::Click($c.X, $c.Y)
    Log "coordinate click '$key' at $($c.X),$($c.Y)"
}

$StudioExe = (Get-Content (Join-Path $OutDir "studio-exe.txt") -Raw).Trim()
Log "Studio exe: $StudioExe"
Log "Place: $PlacePath"

# --- 1. Start desktop recording (whole session; trimmed later) ---
$SessionMp4 = Join-Path $OutDir "session.mp4"
$ff = Start-Process -FilePath "ffmpeg" -ArgumentList @(
    "-y", "-video_size", "1024x768", "-framerate", "30",
    "-f", "gdigrab", "-i", "desktop",
    "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
    # Fragmented MP4: the file stays playable even if ffmpeg is killed
    # instead of quitting cleanly (moov is written up front, not at the end).
    "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
    "`"$SessionMp4`"") -PassThru -NoNewWindow
Log "ffmpeg recording started (PID $($ff.Id))"
Start-Sleep -Seconds 2
Shot "00-desktop-before-studio"

# --- 2. Open the place in headed Studio ---
$studio = Start-Process -FilePath $StudioExe -ArgumentList "`"$PlacePath`"" -PassThru
Log "Studio started (PID $($studio.Id)); waiting for its window ..."
$win = $null
for ($i = 0; $i -lt 36; $i++) {
    Start-Sleep -Seconds 5
    $studio.Refresh()
    if ($studio.MainWindowHandle -ne 0) { $win = $studio; break }
    Shot ("01-wait-" + $i)
}
if (-not $win) {
    Log "FAIL: Studio produced no window in 180 s"
    Shot "02-no-window"
    "STUDIO_NO_WINDOW" | Out-File (Join-Path $OutDir "FAIL.txt")
    exit 3
}
Log "Studio window found: $($studio.MainWindowTitle)"
Start-Sleep -Seconds 15   # let the editor + plugins load
Shot "03-studio-open"

# --- 3. GO / NO-GO: login screen? ---
$title = $studio.MainWindowTitle
if ($title -match "Log ?in|Sign ?in" -or $title -eq "") {
    Log "STOP: Studio appears to be on a login screen (title: '$title')"
    "Studio stopped on a login screen. No login was attempted. See PLAN.md for the fallback (throwaway account)." |
        Out-File (Join-Path $OutDir "LOGIN_REQUIRED.txt")
    Shot "04-login-screen"
    exit 2
}
Log "No login screen detected (title: '$title')"

# --- 4. Open Keynova ---
$root = [System.Windows.Automation.AutomationElement]::FromHandle($studio.MainWindowHandle)
if (-not (Click-UIA $root "Plugins")) { Click-At "PluginsTab" }
Start-Sleep -Seconds 3
Shot "05-plugins-tab"
if (-not (Click-UIA $root "Keynova")) { Click-At "KeynovaButton" }
Start-Sleep -Seconds 5
Shot "06-keynova-open"

# Load the pre-built save. Keynova lists saves from ServerStorage/KeynovaSaves.
if (-not (Click-UIA $root "keynova-test-scene")) { Click-At "SaveEntry" }
Start-Sleep -Seconds 3
Shot "07-save-loaded"

# --- 5. Play + record 5 s ---
$playAt = Get-Date
if (-not (Click-UIA $root "Play")) {
    Log "Play button not found by name; trying Space key"
    [Win32]::PressSpace()
}
Log "Play pressed at $playAt"
Start-Sleep -Seconds 6
Shot "08-playing"

# --- 6. Stop recording, trim the 5 s clip ---
try { $ff.StandardInput.WriteLine("q") } catch {}
if (-not $ff.WaitForExit(15000)) { Stop-Process -Id $ff.Id -Force }
Log "ffmpeg stopped; session file: $((Get-Item $SessionMp4 -ErrorAction SilentlyContinue).Length) bytes"
try { Stop-Process -Id $studio.Id -Force } catch {}
Start-Sleep -Seconds 2

$ClipMp4 = Join-Path $OutDir "keynova-test-scene.mp4"
# The clip starts ~0.5 s after Play was pressed (let the pose settle).
$offset = 2.5  # seconds into the session recording when Play happened, approx:
# recompute properly from the log timestamps is overkill for run 1 -- instead
# trim by seeking to (session_start -> play) using the recorded wall times.
$sessionStart = $ff.StartTime
$skip = ($playAt - $sessionStart).TotalSeconds + 0.5
Log "trimming: skip $skip s, take 5 s"
& ffmpeg -y -v error -ss $skip -i $SessionMp4 -t 5 `
    -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p $ClipMp4
if (-not (Test-Path $ClipMp4)) {
    Log "FAIL: clip was not produced"
    "CLIP_FAILED" | Out-File (Join-Path $OutDir "FAIL.txt")
    exit 4
}
$probe = & ffprobe -v error -show_entries format=duration `
    -show_entries stream=codec_name,width,height,r_frame_rate,nb_frames `
    -of default=noprint_wrappers=1 $ClipMp4
Log "ffprobe clip:`n$probe"
$dur = [double](($probe | Select-String "duration=([0-9.]+)").Matches.Groups[1].Value)
@"
# Keynova test -- driver result
- Clip: keynova-test-scene.mp4
- Duration: $dur s (want 5.000)
- Play pressed at: $playAt (UTC: $($playAt.ToUniversalTime()))
- Trim skip: $skip s
- Login required: NO (editor opened)
- Screenshots: shot-00..shot-08 in this folder
- Check the frames by eye before judging: walk / stop / scared look-up / push-in.
"@ | Out-File (Join-Path $OutDir "RESULT.md") -Encoding utf8
if ([Math]::Abs($dur - 5.0) -gt 0.2) {
    Log "WARN: clip duration $dur is not ~5 s -- check the trim offset"
}
Log "DONE"
exit 0
