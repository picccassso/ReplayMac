# ReplayMac

<img src="ReplayMac_icon.png" alt="ReplayMac icon" width="220" />

ReplayMac is a macOS menu bar instant-replay clipper.

It continuously buffers recent screen/audio capture and saves the last N seconds to an MP4 when triggered.

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
