# ReplayMac

<img src="ReplayMac_icon.png" alt="ReplayMac icon" width="220" />

[![Download on the Mac App Store](https://tools.applemediaservices.com/api/badges/download-on-the-mac-app-store/black/en-us?size=250x83)](https://apps.apple.com/us/app/replaycap/id6789296427?mt=12)

> Note: ReplayMac on the Mac App Store is called **ReplayCap** — same app, different name (see above). It's a one-time purchase that supports development.

ReplayMac is a macOS menu bar instant-replay clipper.

It continuously buffers recent screen/audio capture and saves the last N seconds to an MP4 when triggered. Recording and save state stay visible in the menu bar so you always know what the app is doing.

## Features

- **Instant replay** — Continuously buffers the last N seconds (15–300) of screen and audio; save retroactively with a click or hotkey.
- **Session recording** — Record until you stop, then save one file with screen, system audio, and microphone (menu bar or hotkey). Video is saved without re-encoding, so saves are near-instant and keep the capture codec.
- **Automatic game recording** — Opt in to stay idle until a game launches, record only while you're playing, and stop when the last game quits. Games are detected by their App Store category, with a manual bundle-identifier list for titles that don't declare one (many Steam games). Exclude launchers and tools by choosing a running app or app bundle, or use built-in presets for common launchers and game-development tools.
- **Display priorities and recovery** — Rank preferred screens for single-display capture. ReplayMac uses the highest-priority connected display, falls back automatically when it is unavailable, and returns to it after wake, reconnect, dock/KVM, or clamshell changes.
- **Dual display support** — Capture one or two monitors, saved as a side-by-side composite or as separate files; temporary single-screen fallbacks do not overwrite the saved dual-display setup.
- **Optional HDR recording** — Enable **Settings → Video → Record in HDR** on Apple silicon to capture 10-bit HEVC with Rec.2020 HLG colour. Supports a single display or dual displays saved as separate files; combined side-by-side recordings remain SDR. HDR is off by default and requires HDR source content to preserve HDR highlights. Saved clips and cropped video exports retain HDR; playback appearance depends on your display and player.
- **Hardware-accelerated encoding** — HEVC or H.264 via VideoToolbox, with configurable resolution, frame rate, and bitrate.
- **Retina-aware recording** — Record HiDPI displays at their backing pixel resolution while keeping the macOS UI at its comfortable scaled size.
- **System audio + microphone** — Capture all apps, no audio, or one selected app. Mic and system audio merge into a single track by default; optionally keep them as separate tracks inside the MP4. Audio is aligned to the saved video's keyframe-based start, with real startup gaps padded so clips begin in sync.
- **Live audio level meters** — Real-time RMS-based level meters for system audio and microphone in audio settings.
- **Ring buffer memory management** — Configurable memory cap (256 MB–4 GB) shared across all replay buffers, with automatic eviction under memory pressure.
- **Extended replay buffer** — Optionally roll 5, 10, or 30 minute replay windows to disk, with SSD write and disk usage warnings before enabling.
- **Configurable hotkeys** — Save clip, toggle recording, save last 15s, save last 60s, save extended replay, start/stop session recording, open clip library.
- **Clip library** — Browse, preview, trim, crop, export, or export as GIF; rename, tag, favorite, delete, and batch-act on multiple clips at once. The dual-handle trim selector previews and loops exactly the selected range.
- **Crop on export** — Drag a crop area directly over the preview, or snap it to 16:9, 1:1, 4:3, or 9:16; the crop applies to both MP4 and GIF exports.
- **Configurable trim exports** — Keep the original resolution or scale to 1080p/720p, choose Source, Compact, Balanced, or High quality, and see a live estimated file size with a Discord 100 MB indicator. Unchanged exports retain the fast passthrough path; controlled exports use hardware-accelerated HEVC while preserving supported colour and HDR metadata.
- **Clip sharing** — Open the macOS share sheet or copy a clip file for pasting into another app.
- **Clip organization** — Search clips, mark favorites, add display names, tags, and notes.
- **Storage cleanup** — View total library size and move non-favorite clips to Trash by age or in bulk.
- **Capture profiles** — Save named video/audio/buffer configurations and switch between them on demand.
- **Customizable file-name templates** — Name clips with `{app}`, `{date}`, and `{time}` tokens, with selectable date and time formats and a live preview in Settings > General.
- **Quality presets** — Performance, Quality, Ultra, and Custom modes that tune resolution, frame rate, and bitrate together.
- **Live settings** — Capture, encoding, and audio changes apply while recording; no restart required.
- **Reliable save flow** — Preflight checks block saves when not recording, while the buffer is filling, or when disk space is too low.
- **Clear menu bar status** — Live badge shows recording state, buffered time, and save progress. Last saved clip is one click away from the menu.
- **Notifications** — Optional sound and banner on save, with Open and Reveal in Finder actions on the notification; operational alerts for failures and capture events.
- **Launch at login & auto-start** — Optionally begin recording automatically on login.
- **Update availability check** — Checks GitHub Releases on launch and shows a download link in the menu when a newer version is available.

## Requirements

- macOS 15+
- Apple Silicon or Intel — builds from 1.6.9 onward are universal binaries. Earlier releases are Apple Silicon only.
- Swift 6

## Download

Grab the latest release from the [Releases](https://github.com/picccassso/ReplayMac/releases) page. Updates are manual — download new releases from GitHub when you want to upgrade.

ReplayMac is notarized by Apple, so it opens like any other app — no Gatekeeper workarounds needed.

> Prefer the App Store? The same app is published there as **[ReplayCap](https://apps.apple.com/us/app/replaycap/id6789296427?mt=12)**, a one-time purchase that helps fund development and updates itself through the App Store.

## Build from source

```bash
./build-app.sh
```

This compiles the app and outputs `dist/ReplayMac.app`.

For repeated local development installs, use:

```bash
./scripts/install-dev.sh
```

That builds and replaces `/Applications/ReplayMac.app` while preserving its
settings and macOS permissions. To test the complete first-run flow again:

```bash
./scripts/install-dev.sh --fresh
```

Fresh mode clears ReplayMac's onboarding state and cache, resets Screen
Recording and Microphone access, preserves saved clips, and leaves the app
closed. Add `--launch` when you want it opened after installation, or
`--no-build` to install the existing `dist/ReplayMac.app`.

## Output directory

Saved clips are written to:

`~/Movies/ReplayMac/`

ReplayMac exports MP4 clips. It does not create a separate `.aac` sidecar file; when audio merging is turned off, the system and microphone audio are stored as separate audio tracks inside the saved MP4.

When the extended replay buffer is enabled, ReplayMac also writes temporary rolling segments to a hidden `.ReplayCapLongBuffer` folder inside the output directory. Those segments are rotated automatically and removed when extended replay is disabled or recording stops.

Clip library notes, tags, display names, and favorite state are stored in a hidden `.ReplayCapClipLibrary.json` file inside the output directory. (These internal names are shared with the App Store edition; existing `.ReplayMac…` files are migrated automatically.)

## Capture resolution

ReplayMac shows display sizes as macOS logical resolutions, which can be lower than the physical pixel resolution on Retina and other HiDPI displays. In Settings > Video:

- **Current** records at the logical resolution macOS reports.
- **Retina** records HiDPI displays at their backing pixel resolution when available, without changing the macOS UI scale.
- **Half** records at half of the current logical display size.
- **Custom** forces the saved video to the exact width and height you choose, rescaling the capture if needed.

For dual-display recording, Retina is applied per display. HiDPI displays use their backing pixel size, while non-Retina displays stay at their current size before ReplayMac saves either a side-by-side composite or separate files.

## Capture display priority

For single-display recording, Settings > Video lists connected and remembered displays in priority order. Use the arrow controls to rank them. ReplayMac records the first connected display in that list, whether capture starts manually, at login, for a session recording, or automatically when a game launches.

Disconnected displays stay in the list as offline placeholders. If the preferred display is unavailable, ReplayMac uses the next connected screen and marks it as a fallback in the menu bar. When a higher-priority display reconnects or finishes waking, capture re-targets it automatically. The priority order is included in capture profiles and survives reboots, docking changes, and display ID reassignment.

<details>
<summary>Screenshots</summary>

> These screenshots were captured before the ReplayMac rename and may still show the former ReplayMac name. They will be refreshed with the next release.

<table>
  <tr>
    <th width="50%">General</th>
    <th width="50%">Audio</th>
  </tr>
  <tr>
    <td width="50%"><img src="app_photos/1_general_settings.png?v=1.6.5" alt="General settings" width="100%"></td>
    <td width="50%"><img src="app_photos/3_audio_settings.png?v=1.6.5" alt="Audio settings" width="100%"></td>
  </tr>
</table>

| Video | Video extended replay |
| --- | --- |
| ![Video settings](app_photos/2_video_settings_1.png?v=1.6.5) | ![Video settings extended replay](app_photos/2_video_settings_2.png?v=1.6.5) |

| Profiles | Profile details |
| --- | --- |
| ![Profile settings](app_photos/4_profile_settings_1.png?v=1.6.5) | ![Profile settings details](app_photos/4_profile_settings_2.png?v=1.6.5) |

| Advanced | Hotkeys |
| --- | --- |
| ![Advanced settings](app_photos/6_advanced_settings.png?v=1.6.5) | ![Hotkey settings](app_photos/5_hotkey_settings.png?v=1.6.5) |

| Clip library | Clip details | Storage cleanup | Batch actions |
| --- | --- | --- | --- |
| ![Clip library](app_photos/7_library_view_1.png?v=1.6.5) | ![Clip library details](app_photos/7_library_view_2.png?v=1.6.5) | ![Clip library cleanup](app_photos/7_library_view_3.png?v=1.6.5) | ![Clip library batch actions](app_photos/7_library_view_4.png?v=1.6.5) |

</details>

## Troubleshooting

**Can't record a hotkey in Settings?** Some macOS versions (currently the macOS 27 "Golden Gate" betas) have a system bug that stops the shortcut recorder from registering key presses. You can set every hotkey from the Terminal instead — see [Setting ReplayMac Hotkeys from the Terminal](docs/manual-hotkey-setup.md).

## Support

If you like ReplayMac and want to support its development, consider leaving a tip on [Ko-fi](https://ko-fi.com/picccassso). 🙂

## License

ReplayMac is free and source-available.

You may download, use, inspect, build, and modify it for personal use, but you may not redistribute modified builds, publish renamed forks, sell the app, or use the ReplayMac name/icon/branding without permission.

See [LICENSE.md](LICENSE.md).
