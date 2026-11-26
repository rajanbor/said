# Changelog

Said follows [Semantic Versioning](https://semver.org/).

## [0.5.0] - 2026-11-26

- **A card when the recording ends.** Stop a recording and a small card appears under the menu bar: what was saved, and what Said is still doing with it — saving, transcribing (with how far it has got), writing the summary. It goes away by itself, waits while the pointer is on it, and when the transcript is ready it comes back with a button that opens it.
- **Less waiting after a long recording.** The transcription model is now loaded while you are still recording, so nothing has to wait for it when you stop, and transcribing no longer runs at the slow pace macOS gives to apps in the background. The transcription itself is as fast as the Neural Engine can go: a 25-minute recording takes a bit under two minutes, and the card and the menu now show how far it has got instead of just spinning.
- **Almost nothing while Said sits idle.** A hidden recording pill kept its animation running, which redrew it off-screen about 60 times a second and cost around 5% of a CPU core for as long as Said was open; hidden panels now let go of their contents. Meetings are noticed through Core Audio notifications instead of a check every two seconds, and the transcription model (about 220 MB) is only in memory while it is needed — from the start of a recording until a little after the transcript is written — instead of from launch onwards.

## [0.4.4] - 2026-11-18

- **Summaries.** Said can put a short summary at the top of each transcript: what it was about, the key points, decisions and who does what next. It's written on your Mac by a small open model run with llama.cpp. Pick the model in the menu under **Summaries** and click **Download summary model**:
  - **Bielik 4.5B** (2.9 GB) if you mostly speak Polish;
  - **Qwen3 4B** (2.5 GB) for Polish and English mixed, or mostly English;
  - **Qwen3 1.7B** (1.1 GB) if you want it light.

  You can also choose it at install: `curl -fsSL https://raw.githubusercontent.com/rajanbor/said/main/install.sh | SAID_SUMMARY=bielik bash`. The model is downloaded only when you click, and is checked against a SHA-256 hash before it's used. Transcripts of only a few words get no summary.
- **Fix: no more made-up text in silence.** Whisper used to write phrases like "Thank you for watching" or "Спасибо" for quiet parts of a recording. Said now drops segments without speech, measured by loudness, and takes the language from the parts where people actually talk.

## [0.4.3] - 2026-11-18

- Every new recording starts with the pill at the bottom centre of the screen. You can still drag it anywhere while recording, but Said no longer keeps that spot for the next recording.

## [0.4.2] - 2026-11-18

- **Fix: the pill can be dragged again.** AppKit's "move window by background" doesn't reach SwiftUI content, so dragging the recording pill (and the meeting prompt) did nothing. The pill now moves with a SwiftUI drag gesture; its buttons still work as before, and its new position is saved as soon as you let go.

## [0.4.1] - 2026-11-18

Security fixes from an audit of 0.4.0.

- **`said://start` and `said://toggle` no longer record by themselves.** Any app or web page can open these links, so they now show a “Start recording?” pill you have to click. The pill ignores clicks for its first 0.7 s. `said://stop` is unchanged.
- **No silent widening to all system audio.** If the meeting app's audio can't be found, Said records the microphone only and tells you. It no longer falls back to everything the Mac plays.
- **No lost recordings on save errors.** Temporary tracks are deleted only after the final file is confirmed playable. If mixing or moving fails, the tracks are kept.
- **Private files.** `~/Music/Said` and recording folders are `0700`; audio and transcripts are `0600`.
- **Signing key.** The local signing keychain uses a random password stored in a `0600` file instead of a fixed one, and existing keychains are migrated. Temporary key files are removed on any exit (`trap`), and the build runs with `umask 077`.
- **Installer.** It remembers which commit each release tag pointed to and refuses to install if an installed release is rewritten. It prints the commit it builds and keeps `~/.said` private.
- Added `SECURITY.md`.

## [0.4.0] - 2026-11-18

- **English interface.** The app is now in English, with a Polish translation. Said follows your system language.
- Transcript headings (File, Duration, Language, Transcript) are in the same language as the app.
- Permission prompts are translated too.
- Translations live in `Resources/<language>.lproj`, so adding a language means adding one file (see README).

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
