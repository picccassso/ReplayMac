# ReplayMac Privacy Policy

**Last updated: 12 October 2026**

ReplayMac is distributed on the Mac App Store under the name **ReplayCap**; this policy covers both editions.

ReplayMac does not collect, store, transmit, or share any personal data.

## What happens on your Mac, stays on your Mac

- **Screen and audio recordings** are processed entirely on your Mac and saved only to the output folder you choose (by default `~/Movies/ReplayMac`). They are never uploaded anywhere.
- **Clip metadata** (names, tags, notes, favorites) is stored in a local file inside your output folder.
- **Settings** are stored locally in the app's preferences.

## No collection of any kind

ReplayMac contains no analytics, no telemetry, no crash reporting, no advertising, no user accounts, and no third-party SDKs that phone home. Nothing is ever sent to the developer or to any server on the internet.

The Mac App Store version (ReplayCap) never connects out to the internet. Its only network feature is the optional Companion server described below, which is off until you turn it on.

The version distributed on GitHub also makes one type of outgoing request: an optional check of the public GitHub Releases page at launch to see whether a newer version exists. This request sends no personal information beyond what any web request inherently includes, and nothing about it is logged or stored by the developer.

## Companion app (optional)

If you turn on **Companion** in settings, ReplayMac listens on your local network so the ReplayCap Companion app on your own phone or tablet can control it. It works like this:

- Your Mac announces itself on the local network (Bonjour) so the phone can find it. The announcement includes the server name you see in settings and a random ID for this Mac.
- A phone can only connect after you approve it on your Mac. Approved phones are remembered on your Mac (their name and a random ID), along with a pairing key used to recognise them. You can remove them at any time in Companion settings.
- While connected, your Mac sends the phone what it needs to show: recording status, timers, the names, sizes and thumbnails of recently saved clips, and the name of the captured display. The phone can start and stop recording, save clips, show a clip in Finder and move a clip to the Trash.
- This traffic stays between your Mac and your phone on your network. It is not encrypted, so use a network you trust or a cable. None of it goes to the developer or anyone else.

macOS will ask for Local Network permission the first time you turn the server on.

## Permissions

ReplayMac asks macOS for Screen Recording (and optionally Microphone) permission solely to create the recordings you ask it to make. If you turn on the Companion server, it also asks for Local Network permission so your phone can reach it. You can revoke these at any time in System Settings → Privacy & Security.

## Questions

Open an issue at [github.com/picccassso/ReplayMac](https://github.com/picccassso/ReplayMac/issues).
