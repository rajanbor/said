<img src="Resources/AppIcon.png" width="96" alt="">

# Said

A small, **local-first** voice recorder for macOS (the app's interface is in Polish for now). Click the icon in the menu bar, talk, click stop, and get the recording plus a transcript. Nothing is sent to the cloud.

**Website:** https://rajanbor.github.io/said/ ([Polska wersja](https://rajanbor.github.io/said/pl/))

## Install

Paste into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/rajanbor/said/main/install.sh | bash
```

The script downloads the latest release into `~/.said/src`, builds the app on your Mac and installs `Said.app` into `/Applications`. If `/Applications` isn't writable, it uses `~/Applications`. You need macOS 14 or later and the Xcode Command Line Tools; the script offers to install them. Run the same command again to update.

To install the latest code from `main` instead of the newest release:

```bash
curl -fsSL https://raw.githubusercontent.com/rajanbor/said/main/install.sh | SAID_VERSION=main bash
```

Uninstall:

```bash
rm -rf /Applications/Said.app ~/.said "$HOME/Library/Application Support/Said"
```

## What it does

- **Menu bar only.** No Dock icon.
- **Floating pill.** While you record, a small black pill sits at the bottom of the screen with a live waveform, a timer and a stop button. Drag it anywhere; Said remembers the spot. It never steals focus.
- **Meeting detection.** When Zoom, Microsoft Teams, Google Meet (in a browser), Webex, FaceTime, Slack, Discord or WhatsApp starts using the microphone, Said offers to record and transcribe. When the call ends, recording stops on its own.
- **The other side of the call.** Meeting recordings include the meeting app's audio, so the other participants' voices are captured too, even on headphones.
- **Local transcription.** Polish, English and many other languages, detected automatically.
- **Silence and disk warnings.** After 2 minutes of silence, Said sends a notification with a **Stop recording** (*Zatrzymaj nagrywanie*) button. It also warns when the disk is getting full and stops safely before it runs out.
- **One folder per recording:**

  ```
  ~/Music/Said/2026-11-18_10-15-00/
    said_2026-11-18_10-15-00.m4a   audio (mic + call audio mixed)
    said_2026-11-18_10-15-00.md    transcript with timestamps
  ```

## How it works

Said is a native Swift app (SwiftUI + AppKit). It uses only Apple frameworks plus [WhisperKit](https://github.com/argmaxinc/WhisperKit).

1. **Recording.** The microphone is recorded with `AVAudioRecorder`. For meetings, a Core Audio **process tap** (macOS 14.2+) captures only the meeting app's audio, encoded to AAC on the fly. After you stop, both tracks are mixed into one `.m4a`.
2. **Meeting detection.** Every 2 seconds Said asks Core Audio which processes are currently using a microphone, and checks their bundle IDs against known meeting apps. It doesn't read window titles or browser tabs, and it needs no extra permission.
3. **Transcription, on your Mac.** The audio goes through **Whisper large-v3 turbo**, an open speech-recognition model converted to Core ML. It runs on the Apple Neural Engine and GPU of your Mac, with no server involved. On an M-series Mac, 10 seconds of audio takes about 1.5 seconds. The result is saved as Markdown next to the audio.
4. **The only network access** is downloading that model once (~630 MB from Hugging Face), when you click **Pobierz model transkrypcji** (*Download transcription model*) in the menu. After that the model loads from `~/Library/Application Support/Said/Models` with downloads switched off.

### Permissions

macOS asks for:

- **Microphone**, to record your voice;
- **System audio recording**, for meeting audio. This is not screen recording;
- **Notifications**, for the silence and disk warnings.

Said keeps these permissions across updates. It is signed with a local, self-signed certificate (“Said Local Signing”), kept in its own keychain at `~/.said/signing`; your login keychain isn't touched. With ad-hoc signing, macOS would treat every new build as a different app and ask again.

### URL scheme

`said://start`, `said://stop` and `said://toggle` control recording from Shortcuts, Raycast, Alfred or Terminal (`open said://toggle`).

## Build from source

```bash
./scripts/build-app.sh --open
```

```
Sources/Said/
  SaidApp.swift          menu bar app, URL handling
  MenuView.swift         menu contents
  PillPanel.swift        floating pills: recording and meeting prompt
  Recorder.swift         recording state, files, silence and disk watch
  MeetingDetector.swift  which meeting app is using the mic (Core Audio)
  SystemAudioTap.swift   app or system audio (Core Audio process tap)
  AudioMixer.swift       mixes mic + system audio into one .m4a
  Transcriber.swift      WhisperKit: model download, transcription to .md
  Notifier.swift         notifications with a Stop action
Resources/               Info.plist, AppIcon.icns
scripts/build-app.sh     builds and signs build/Said.app
scripts/release.sh       cuts a release (tag + GitHub release)
scripts/make-icon.swift  renders the app icon
install.sh               one-line installer
docs/                    website (GitHub Pages), English + Polish
```

## Versioning

Said follows [SemVer](https://semver.org/). Changes are listed in [CHANGELOG.md](CHANGELOG.md), and the version is shown at the top of the menu.

To cut a release, add a `## [X.Y.Z] - date` section to `CHANGELOG.md`, then run:

```bash
./scripts/release.sh X.Y.Z
```

It bumps the version in `Info.plist`, checks that the app builds, commits, tags `vX.Y.Z`, pushes, and creates the GitHub release.

## Roadmap

- Speaker labels (“You” vs “Others” from the two tracks)
- Meeting notes (summary, decisions, tasks) from a local LLM (Ollama)
- Global keyboard shortcut
- English UI (the app is in Polish for now)

Please let people know when you record them.

## License

MIT
