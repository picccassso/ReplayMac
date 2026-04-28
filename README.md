# ReplayMac

<img src="ReplayMac_icon.png" alt="ReplayMac icon" width="220" />

ReplayMac is a macOS menu bar instant-replay clipper.

It continuously buffers recent screen/audio capture and saves the last N seconds to an MP4 when triggered.

## Features

- **Instant replay** — Continuously buffers the last N seconds (15–300) of your screen and audio. Save retroactively with a click or hotkey.
- **Dual display support** — Capture one or two monitors, saved as a side-by-side composite or as separate files.
- **Hardware-accelerated encoding** — HEVC or H.264 via VideoToolbox, with configurable resolution, frame rate (30/60/120 fps), and bitrate (10–50 Mbps).
- **System audio + microphone** — Separate AAC tracks for system audio and mic with independent volume controls.
- **Ring buffer memory management** — Configurable memory cap (256 MB–4 GB) with automatic eviction under system memory pressure.
- **Four configurable hotkeys** — Save clip, toggle recording, save last 15s, save last 60s — assign any key combination.
- **Clip library** — Browse, preview, play, reveal in Finder, or delete saved clips from a built-in library window.
- **Quality presets** — Performance, Quality, Ultra, and Custom modes that tune resolution, frame rate, and bitrate together.
- **Audio cue & notifications** — Optional sound and macOS notification when a clip is saved.
- **Launch at login & auto-start** — Optionally begin recording automatically on login.
- **Sparkle auto-updates** — Checks for new versions daily.
- **Persistent menu bar app** — Runs in the background with a live status badge showing recording state and buffer usage.

## Requirements

- macOS 15+
- Swift 6

## Download

Grab the latest release from the [Releases](https://github.com/alex/ReplayMac/releases) page.

> **Note:** ReplayMac is not notarized. On first launch, right-click the app and select **Open** to bypass Gatekeeper.

## Build from source

```bash
./build-app.sh
```

This compiles the app and outputs `dist/ReplayMac.app`.

## Output directory

Saved clips are written to:

`~/Movies/ReplayMac/`

<details>
<summary>Screenshots</summary>

![General settings](app_photos/1_general_settings.png)
![Video settings](app_photos/2_video_settings.png)
![Audio settings](app_photos/3_audio_settings.png)
![Hotkey settings](app_photos/4_hotkey_settings.png)
![Advanced settings](app_photos/5_advanced_settings.png)
![Clip library](app_photos/6_library.png)

</details>
