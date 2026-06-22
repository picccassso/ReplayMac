# ReplayMac

<img src="ReplayMac_icon.png" alt="ReplayMac icon" width="220" />

ReplayMac is a macOS menu bar instant-replay clipper.

It continuously buffers recent screen/audio capture and saves the last N seconds to an MP4 when triggered. Recording and save state stay visible in the menu bar so you always know what the app is doing.

## Features

- **Instant replay** — Continuously buffers the last N seconds (15–300) of screen and audio; save retroactively with a click or hotkey.
- **Dual display support** — Capture one or two monitors, saved as a side-by-side composite or as separate files.
- **Hardware-accelerated encoding** — HEVC or H.264 via VideoToolbox, with configurable resolution, frame rate, and bitrate.
- **System audio + microphone** — Capture all apps, no audio, or one selected app. Mic and system audio merge into a single track by default; optionally keep as separate tracks inside the MP4.
- **Live audio level meters** — Real-time RMS-based level meters for system audio and microphone in audio settings.
- **Ring buffer memory management** — Configurable memory cap (256 MB–4 GB) shared across all replay buffers, with automatic eviction under memory pressure.
- **Extended replay buffer** — Optionally roll 5, 10, or 30 minute replay windows to disk, with SSD write and disk usage warnings before enabling.
- **Six configurable hotkeys** — Save clip, toggle recording, save last 15s, save last 60s, save extended replay, open clip library.
- **Clip library** — Browse, preview, trim, export, or export as GIF; rename, tag, favorite, and batch-act on multiple clips at once.
- **Clip sharing** — Open the macOS share sheet or copy a clip file for pasting into another app.
- **Clip organization** — Search clips, mark favorites, add display names, tags, and notes.
- **Storage cleanup** — View total library size and move non-favorite clips to Trash by age or in bulk.
- **Capture profiles** — Save named video/audio/buffer configurations and switch between them on demand.
- **Customizable file-name templates** — Name clips with `{app}`, `{date}`, and `{time}` tokens, with a live preview in Settings > General.
- **Quality presets** — Performance, Quality, Ultra, and Custom modes that tune resolution, frame rate, and bitrate together.
- **Live settings** — Capture, encoding, and audio changes apply while recording; no restart required.
- **Reliable save flow** — Preflight checks block saves when not recording, while the buffer is filling, or when disk space is too low.
- **Clear menu bar status** — Live badge shows recording state, buffered time, and save progress. Last saved clip is one click away from the menu.
- **Notifications** — Optional sound and banner on save, with Open and Reveal in Finder actions on the notification; operational alerts for failures and capture events.
- **Launch at login & auto-start** — Optionally begin recording automatically on login.
- **Update availability check** — Checks GitHub Releases on launch and shows a download link in the menu when a newer version is available.

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

ReplayMac exports MP4 clips. It does not create a separate `.aac` sidecar file; when audio merging is turned off, the system and microphone audio are stored as separate audio tracks inside the saved MP4.

When the extended replay buffer is enabled, ReplayMac also writes temporary rolling segments to a hidden `.ReplayMacLongBuffer` folder inside the output directory. Those segments are rotated automatically and removed when extended replay is disabled or recording stops.

Clip library notes, tags, display names, and favorite state are stored in a hidden `.ReplayMacClipLibrary.json` file inside the output directory.

<details>
<summary>Screenshots</summary>

<table>
  <tr>
    <th width="50%">General</th>
    <th width="50%">Audio</th>
  </tr>
  <tr>
    <td width="50%"><img src="app_photos/1_general_settings.png?v=1.6" alt="General settings" width="100%"></td>
    <td width="50%"><img src="app_photos/3_audio_settings.png?v=1.6" alt="Audio settings" width="100%"></td>
  </tr>
</table>

| Video | Video extended replay |
| --- | --- |
| ![Video settings](app_photos/2_video_settings_1.png?v=1.6) | ![Video settings extended replay](app_photos/2_video_settings_2.png?v=1.6) |

| Profiles | Profile details |
| --- | --- |
| ![Profile settings](app_photos/4_profile_settings_1.png?v=1.6) | ![Profile settings details](app_photos/4_profile_settings_2.png?v=1.6) |

| Advanced | Hotkeys |
| --- | --- |
| ![Advanced settings](app_photos/6_advanced_settings.png?v=1.6) | ![Hotkey settings](app_photos/5_hotkey_settings.png?v=1.6) |

| Clip library | Clip details | Storage cleanup | Batch actions |
| --- | --- | --- | --- |
| ![Clip library](app_photos/7_library_view_1.png?v=1.6) | ![Clip library details](app_photos/7_library_view_2.png?v=1.6) | ![Clip library cleanup](app_photos/7_library_view_3.png?v=1.6) | ![Clip library batch actions](app_photos/7_library_view_4.png?v=1.6) |

</details>

## License

ReplayMac is free and source-available.

You may download, use, inspect, build, and modify it for personal use, but you may not redistribute modified builds, publish renamed forks, sell the app, or use the ReplayMac name/icon/branding without permission.

See [LICENSE.md](LICENSE.md).