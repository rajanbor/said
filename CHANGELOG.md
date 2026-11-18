# Changelog

Said follows [Semantic Versioning](https://semver.org/).

## [0.3.1] - 2026-11-18

- **Silence warning.** After 2 minutes without sound, Said sends a notification with a **Stop recording** button, and shows the same warning in the menu.
- **Disk space.** Said warns when less than 2 GB is free, and stops and saves the recording before free space drops below 500 MB. It won't start recording when space is already that low.
- **Smaller files.** Meeting and system audio is encoded to AAC while recording: about 0.7 MB per minute instead of about 23 MB.
- **Cleaner menu** in the style of native macOS menus: rows with icons and hover highlight, the date of the last recording instead of its file name, settings grouped together, and model status shown only when it needs attention.
- **Open recordings folder** button in the menu.
- English README, changelog and website, plus a Polish version of the website.

## [0.3.0] - 2026-11-18

- Meeting recordings include the meeting app's audio (Zoom, Teams, browser…), mixed with the microphone into one file, so the other participants' voices are captured even on headphones. Uses a Core Audio process tap (macOS 14.2+) and needs no screen-recording permission.
- New menu switch “Nagrywaj dźwięk z komputera” (record system audio) for regular recordings. Off by default.
- `said://start`, `said://stop` and `said://toggle` URLs, e.g. for Shortcuts or Raycast.
- Fix: permission descriptions and the URL scheme added to `Info.plist`.

## [0.2.0] - 2026-11-18

- Meeting detection: when Zoom, Teams, Google Meet (in a browser), Webex, FaceTime, Slack, Discord or WhatsApp starts using the microphone, Said offers to record and transcribe. Recording stops on its own when the call ends. Can be switched off in the menu.
- Said remembers microphone access across updates: it's signed with a stable local certificate instead of an ad-hoc signature. After updating to this version, macOS asks one more time.
- Transcripts of meeting recordings include the name of the app.

## [0.1.0] - 2026-11-18

First release.

- Voice recording from the menu bar, with no Dock icon.
- Small black pill at the bottom of the screen with a live waveform, timer and stop button. It can be dragged, and Said remembers where.
- Local transcription (Whisper large-v3 turbo via WhisperKit) with automatic language detection.
- Each recording in its own folder in `~/Music/Said`, with a Markdown transcript.
- One-line installer (`install.sh`) and project website.
