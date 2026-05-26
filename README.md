# ReplayMac

<img src="ReplayMac_icon.png" alt="ReplayMac icon" width="220" />

ReplayMac is a macOS menu bar instant-replay clipper.

It continuously buffers recent screen/audio capture and saves the last N seconds to an MP4 when triggered. Recording and save state stay visible in the menu bar so you always know what the app is doing.

## Features

- **Instant replay** — Continuously buffers the last N seconds (15–300) of your screen and audio. Save retroactively with a click or hotkey.
- **Dual display support** — Capture one or two monitors, saved as a side-by-side composite or as separate files.
- **Hardware-accelerated encoding** — HEVC or H.264 via VideoToolbox, with configurable resolution, frame rate (30/60/120 fps), and bitrate (10–50 Mbps).
- **System audio modes + microphone** — Record all system audio, no system audio, or only one selected app; microphone is saved as a separate AAC track with its own device and volume controls.
- **Ring buffer memory management** — Configurable total memory cap (256 MB–4 GB) shared across all replay buffers, evicting oldest footage as needed and trimming under system memory pressure.
- **Opt-in extended replay buffer** — Save longer 5, 10, or 30 minute replay windows by rolling temporary segments to disk, with clear SSD write and disk usage warnings before enabling.
- **Four configurable hotkeys** — Save clip, toggle recording, save last 15s, save last 60s — assign any key combination.
- **Clip library + quick trim** — Browse, preview, trim/export, play, reveal in Finder, or delete saved clips from a built-in library window.
- **Quality presets** — Performance, Quality, Ultra, and Custom modes that tune resolution, frame rate, and bitrate together.
- **Live settings** — Capture, encoding, and audio changes apply automatically while recording; no restart required.
- **Reliable save flow** — Preflight checks prevent saving when not recording or while the buffer is still filling; success feedback only appears after the clip is written.
- **Clear menu bar status** — Live badge shows recording state, buffered time, and save progress (Saving / Saved / Failed). Menu includes Start/Stop Recording, buffer usage, and save actions that disable until footage is ready.
- **Audio cue & notifications** — Optional sound and notification when a clip saves successfully; operational notifications for save failures and when recording stops or fails to start (permissions, display disconnect, GPU pressure).
- **Launch at login & auto-start** — Optionally begin recording automatically on login.

## Requirements

- macOS 15+
- Swift 6

## Download

Grab the latest release from the [Releases](https://github.com/picccassso/ReplayMac/releases) page. Updates are manual — download new releases from GitHub when you want to upgrade.

> **Note:** ReplayMac is not notarized. On first launch, right-click the app and choose **Open** to bypass Gatekeeper.

## Build from source

```bash
./build-app.sh
```

This compiles the app and outputs `dist/ReplayMac.app`.

## Output directory

Saved clips are written to:

`~/Movies/ReplayMac/`

When the extended replay buffer is enabled, ReplayMac also writes temporary rolling segments to a hidden `.ReplayMacLongBuffer` folder inside the output directory. Those segments are rotated automatically and removed when extended replay is disabled or recording stops.

<details>
<summary>Screenshots</summary>

![General settings](app_photos/1_general_settings.png?v=1.1)
![Video settings](app_photos/2_video_settings.png?v=1.1)
![Audio settings](app_photos/3_audio_settings.png?v=1.1)
![Hotkey settings](app_photos/4_hotkey_settings.png?v=1.1)
![Advanced settings](app_photos/5_advanced_settings.png?v=1.1)
![Clip library](app_photos/6_library.png?v=1.1)

</details>
