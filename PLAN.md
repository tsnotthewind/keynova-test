# Keynova test on GitHub Actions — PLAN (preparation only)

## The chosen approach, in plain words

A real Windows machine in the cloud (GitHub's free runner) opens Roblox
Studio with a ready-made place, opens the Keynova plugin, loads a
ready-made 5-second animation, plays it, and records the screen. The
video comes out as a downloadable file. Nothing is clicked by a human —
a PowerShell script does the clicking, and it takes a screenshot after
every step so we can see where it got stuck.

Why this approach and not the others:
- **(a) Scripted GUI clicking — CHOSEN, but kept to a minimum.** Keynova
  is a GUI plugin (timeline, dock widget). There is no way around the GUI
  for "open Keynova and press Play". So the script does only 3-4 clicks:
  Plugins tab → Keynova button → the save → Play. Everything else is
  prepared in advance so the clicks are the only fragile part.
- **(b) Keynova's own data format — USED for the preparation.** I read
  Keynova's source (Keynova.rbxmx, 5,309 lines) and built the animation
  in its own v2 JSON format, from the exact same poses as the finished
  Cadence video. The place file already contains the rig AND the save, so
  no keyframing has to happen on the runner at all.
- **(c) Headless Studio (--task RunScript) — REJECTED as the main route.**
  It runs Luau scripts, not plugins: Keynova would never load, so the
  test would not test Keynova. (It stays useful for one thing: proving
  the Studio install works, via `--api`.)
- **(d) Anything else — none found.** No 2026 source shows a scripted
  way to drive a Studio plugin without the GUI.

Fallback if the GUI clicks fail: the recording still proves Studio +
Keynova open; the animation data is Keynova's own, so a later run can
retry just the clicks with corrected coordinates from the screenshots.

## Steps (what happens on the runner)

1. Check out the repo. Install ffmpeg (`choco install ffmpeg -y`).
2. Install Studio silently (`RobloxStudioInstaller.exe /S`), find
   `RobloxStudioBeta.exe`, prove the deploy with `--api`.
3. Copy `Keynova.rbxmx` to `%LOCALAPPDATA%\Roblox\Plugins\`.
4. Start ffmpeg recording the desktop (30 fps, fragmented MP4).
5. Open `test-place.rbxlx` in headed Studio, maximised.
6. **GO / NO-GO: if Studio shows a login screen, stop.** Marker file
   `LOGIN_REQUIRED.txt` + screenshot are uploaded. No login attempted.
7. Click Plugins → Keynova → the `keynova-test-scene` save → Play.
   Record 5 s. Trim the clip, check it with ffprobe.
8. Upload everything (`out/`): clip, 9 screenshots, driver log, Studio
   logs, result file. Retention 30 days.

## What is already prepared (in this folder)

- `test-place.rbxlx` (110 KB) — baseplate + full R15 rig (16 Parts,
  Humanoid, 15 Motor6Ds with C0/C1 computed from the Cadence data) +
  camera (FOV 70) + the Keynova save in ServerStorage/KeynovaSaves.
- `keynova-project.json` (95 KB) — the same animation in Keynova v2
  format: 13 tracks (11 joint "Transform" tracks, 1 root "CFrame"
  track, 1 camera "FieldOfView" track), 12 keys each, 30 fps, 150
  frames. Validated against a Python mirror of Keynova's own
  `Engine.validate()`.
- `build-place.py` — the generator that built both files from
  `../cadence-test/cadence-test-scene.cadence` + `.rbmx`. Re-run it to
  rebuild after any change.
- `Keynova.rbxmx` (326 KB, MIT, by Derpyburger33333) — the plugin itself.
- `scripts/Install-Studio.ps1`, `scripts/Drive-Keynova.ps1`.
- `.github/workflows/keynova-test.yml` — manual trigger only
  (`workflow_dispatch`), `windows-latest`, 120 min cap.

## Top 3 risks (what will most likely break first)

1. **Studio demands a login on first launch — the #1 risk.** Evidence:
   the Lest CI tool's docs say Studio "may be sitting on a login
   screen" when launched in CI, and jest-roblox-cli requires Studio
   "installed (logged in)". If the runner hits this, the run stops at
   step 6 by design. Fallback (needs Rusty): a THROWAWAY Roblox
   account, created just for this test, whose session is passed to the
   runner as a repo secret. Do NOT use Rusty's main account. This is
   the one thing that could block the whole test.
2. **The clicks miss.** Studio is a Qt app; UI Automation may not see
   its buttons, and the coordinate fallbacks are placeholders. Run 1
   is a PROBE: expect to correct coordinates from the screenshots.
3. **Keynova rejects something in the pre-built save.** Two guesses in
   the project are unproven: the root-motion track (property "CFrame"
   on the root Part) and the camera track ("FieldOfView" number track).
   The 11 joint tracks are proven from Keynova's own export code. If
   the save fails to load, the screenshots + Studio log will show
   Keynova's own error, and the fix is to drop the two guessed tracks.

## What is still unknown

- Whether the Studio installer URL / silent flag still work (verify on
  run 1; the script fails fast with the log if not).
- The exact pixel positions of Keynova's buttons at 1024x768.
- Whether Keynova's file list shows the ServerStorage save.
- Whether a runner's datacenter IP triggers Roblox's "too many logins"
  screen if a login is ever attempted.

## What Rusty needs to provide

- GitHub account: DONE — `tsnotthewind` (created 2026-11-17 18:01 IST).
- **A public repo, still needed.** Create an empty public repo (any
  name, e.g. `keynova-test`), then copy the CONTENTS of this folder
  into it — so `.github/` lands at the repo root — commit, push, and
  run the workflow from the Actions tab ("Run workflow"). No secrets,
  no card, no extra setup.
- If run 1 stops at the login screen: decide on the throwaway-account
  fallback (he creates it; nothing of his main account is used).
