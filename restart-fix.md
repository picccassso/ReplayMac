# Restart-Free Settings Changes

## Findings

- ReplayMac is a native SwiftUI/AppKit macOS app built with Swift Package Manager.
- Settings are persisted through `Defaults`, and the UI writes changes immediately.
- Some settings already apply without restarting recording:
  - Buffer duration is observed in `AppDelegate` and pushed into all ring buffers through `syncBufferDurationToSettings()`.
  - System and microphone volume are polled every second in `startMonitoring()` and applied to the active audio processors.
  - Save-time settings such as output directory, watermark, notification, audio cue, and dual save mode are read when saving a clip.
  - Hotkeys are handled by `KeyboardShortcuts` and should not require an app restart.
- The settings that currently require restarting recording are capture/encoder settings because they are only read inside `startCapturePipeline()`:
  - Capture mode.
  - Display selection.
  - Frame rate.
  - SCK queue depth.
  - Microphone capture enabled/disabled.
- Some settings are exposed in the UI but are not currently wired into the pipeline:
  - Video codec.
  - Bitrate.
  - Capture resolution/custom width/custom height.
  - Exclude ReplayMac audio.
  - Microphone device selection.
- `CaptureManager` already has the important building block for restart-free behavior: it stores the current `SCContentFilter` and `SCStreamConfiguration` and can recreate streams internally after SCK `-3821` failures. That same pattern can be generalized for user-driven setting changes.
- ScreenCaptureKit configuration changes cannot all be safely applied by mutating local settings alone. Display/filter changes, frame rate, queue depth, and audio capture behavior need either `SCStream.updateConfiguration`, `SCStream.updateContentFilter`, or a controlled stream swap.
- Video encoder settings such as codec, dimensions, and bitrate require a new `VTCompressionSession`. They cannot be changed reliably on the existing encoder session after it has started.

## Fix To Implement

Implement a runtime settings reconciler owned by `AppDelegate` that observes the relevant `Defaults` keys and applies changes while recording continues.

The reconciler should classify settings into three groups:

1. Live mutable settings.
   Apply directly without touching capture:
   - Buffer duration.
   - Memory cap.
   - System audio volume.
   - Microphone volume.
   - Save/output/notification/watermark options.

2. ScreenCaptureKit stream settings.
   Apply by updating the active stream configuration/filter where possible:
   - Frame rate.
   - Queue depth.
   - Exclude current process audio.
   - Display selection when ScreenCaptureKit accepts a filter update.

3. Pipeline-shape settings.
   Apply through a seamless internal pipeline swap instead of asking the user to stop/start recording:
   - Single vs dual capture mode.
   - Encoder codec.
   - Encoder bitrate.
   - Encoder dimensions/resolution.
   - Microphone enable/disable.
   - Microphone device selection.

For pipeline-shape settings, the app should perform an internal restart of only the affected capture/encoder components:

- Keep the app running.
- Keep the menu bar and settings UI responsive.
- Stop only the affected stream/encoder/mic component.
- Start the replacement component with the latest settings.
- Reattach the existing output handlers to the same ring buffers.
- Clear or segment ring buffers when the encoded format changes, because old and new encoded samples may have incompatible format descriptions.
- Preserve unaffected buffers when safe, especially audio buffers when only video encoder settings change.

The implementation should centralize this behind one method, for example `applyRuntimeSettingsChange`, so UI code does not need to know which settings require direct mutation, SCK update, or a component swap.

The user-facing copy in Settings should then change from "apply after restarting recording" to wording like "changes apply automatically" once the reconciler is implemented.

## Recommended Order

1. Wire all currently unused settings into the pipeline: codec, bitrate, resolution, exclude-own-audio, and microphone device.
2. Add `Defaults.observe` handlers for capture, encoder, and audio source keys in `AppDelegate`.
3. Add `CaptureManager` methods for updating active stream configuration/filter without tearing down the app.
4. Add a controlled component-swap path for settings that require a new stream or `VTCompressionSession`.
5. Update Settings copy after runtime reconfiguration is reliable.
