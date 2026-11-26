<img src="Resources/AppIcon.png" width="96" alt="">

# Said

Said records what you say on your Mac and turns it into text. Click the icon at the top of the screen, talk, click stop. A moment later you have the recording and a transcript, and neither ever leaves your computer.

**Website:** https://rajanbor.github.io/said/ · [po polsku](https://rajanbor.github.io/said/pl/) · [what's new](https://rajanbor.github.io/said/releases.html)

<p>
  <img src="docs/screenshots/pill.webp" width="420" alt="The recording pill at the bottom of the screen: a red dot, a live waveform, the timer 00:09 and a red stop button">
  &nbsp;
  <img src="docs/screenshots/menu.jpg" width="345" alt="The Said menu in the menu bar: Record, Open recordings folder, settings for meeting detection and system audio, and Quit">
</p>

*The pill you see while recording, and the menu. The menu is shown in Polish because Said follows your system language.*

## Install

Open Terminal, paste this and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/rajanbor/said/main/install.sh | bash
```

That's it. It takes a few minutes the first time, because Said is built on your own Mac. You need macOS 14 or newer. If your Mac asks to install Apple's developer tools, say yes and run the command again.

To update later, run the same command.

## Using it

**Recording a thought.** Click the Said icon in the menu bar and choose **Record**. A small black pill appears at the bottom of the screen with a timer and a stop button. Keep working; the pill won't get in your way, and you can drag it wherever you like. Click stop when you're done.

**Recording a call.** When you join a call in Zoom, Teams, Google Meet or similar, Said asks *“Record and transcribe?”*. Click **Record**, and it captures both you and the other people, even if you wear headphones. When the call ends, it stops by itself. Ignore the question and it goes away after 30 seconds.

**When it's done.** A card appears under the menu bar with the recording that was just saved and what Said is still doing with it: transcribing, writing the summary. It disappears on its own, and comes back with an **Open** button when the transcript is ready.

**Finding your recordings.** Each recording gets its own folder in `Music/Said`, with the audio and a text file of everything that was said, with timestamps. The menu has a button that opens that folder.

**Summaries.** Said can also put a short summary at the top of each transcript: what it was about, the key points, decisions, and who does what next. In the menu, under **Summaries**, pick a model and click **Download summary model**. From then on every transcript gets a summary by itself. It's written on your Mac, like the transcript.

**If you forget to stop.** After 2 minutes of silence Said sends a notification with a stop button. If your disk is getting full, it warns you and saves the recording before space runs out.

Before you record other people, let them know.

### Which summary model?

Pick the one that matches how you talk. You can change it any time.

| You mostly speak… | Model | Download |
|---|---|---|
| **Polish** | **Bielik 4.5B**, made for Polish by SpeakLeash | 2.9 GB |
| **Polish and English mixed, or mostly English** | **Qwen3 4B** | 2.5 GB |
| **Anything, and you want it light** (older Mac, little disk space) | **Qwen3 1.7B**: quicker, but shorter and less precise summaries | 1.1 GB |

The summary is written in the language of the recording. A short call takes about ten seconds; long ones are done in parts and take longer.

You can also choose the model when you install, so it's already selected in the menu:

```bash
curl -fsSL https://raw.githubusercontent.com/rajanbor/said/main/install.sh | SAID_SUMMARY=bielik bash
```

Use `bielik`, `qwen3-4b`, `qwen3-1.7b` or `off`. The model itself is still only downloaded when you click the button.

## Your privacy

- **Recordings stay on your Mac.** No cloud, no account, no analytics.
- **The internet is used only for models:** to download the speech-recognition model (about 630 MB) and, if you want summaries, a summary model, each when you click its button in the menu. After that Said works offline.
- **Nothing records without you.** Recording starts only when you click. Links that try to start a recording from another app only show a question you have to answer.
- **Only the call is recorded.** For calls, Said captures the meeting app's sound, not your music or notifications. If it can't tell which sound belongs to the call, it records just your microphone.
- **Only you can open the files.** Other people who use this Mac can't get into your recordings folder.

More details are in [SECURITY.md](SECURITY.md).

## How it works, in short

Said turns speech into text with **Whisper**, an openly available speech-recognition model. It runs on your Mac's own chip, the way your Mac edits photos without a server. Ten seconds of audio takes about a second and a half. Whisper understands Polish, English and many other languages, and works out which one you're speaking by itself.

Summaries are written by a small open language model (Bielik or Qwen) running on your Mac with **llama.cpp**. Nothing is sent anywhere.

To notice that a call has started, Said only checks which app is using the microphone. It doesn't look at your screen, windows or browser tabs.

## Uninstall

```bash
rm -rf /Applications/Said.app ~/.said "$HOME/Library/Application Support/Said"
```

Your recordings in `Music/Said` stay; delete that folder too if you don't need them.

---

## Under the hood

Said is a native Swift app (SwiftUI + AppKit). Apart from [WhisperKit](https://github.com/argmaxinc/WhisperKit) and [llama.cpp](https://github.com/ggml-org/llama.cpp), it uses only Apple's own frameworks.

- **Recording.**
  - The microphone is recorded with `AVAudioRecorder`.
  - For calls, a Core Audio **process tap** (macOS 14.2+) captures only the meeting app's audio, encoded to AAC as it records. It fails closed: no meeting audio means microphone only, never the whole system.
  - The two tracks are mixed into one `.m4a`. Temporary files are deleted only after the result is confirmed playable.
  - Folders are `0700` and files `0600`.
- **Meeting detection.** Every 2 seconds Said asks Core Audio which processes are capturing audio input and matches their bundle IDs against known meeting apps. This needs no permission.
- **Transcription.**
  - The model is **Whisper large-v3 turbo**, converted to Core ML and quantized to about 630 MB. It runs on the Neural Engine and GPU.
  - The model is downloaded only when you click the button. After that it loads with downloads switched off.
  - The transcript is Markdown with timestamps.
  - Whisper tends to invent text for silence ("Thank you for watching", "Спасибо"). Said measures the loudness under each segment and drops the ones without speech, with a stricter level for those typical phrases. The language is taken from the parts with the most speech.
- **Summaries.**
  - llama.cpp comes as the project's own prebuilt `llama.xcframework` (Metal, pinned by checksum in `Package.swift`), so building still needs only the Command Line Tools.
  - Models are GGUF files (Q4_K_M) from Hugging Face. The download is checked against a SHA-256 hash in the code before it's used.
  - One setting picks the model: `summaryModel` = `bielik` | `qwen3-4b` | `qwen3-1.7b` | `off` (menu, `SAID_SUMMARY` at install, or `defaults write io.github.rajanbor.said summaryModel bielik`).
  - The model gets the transcript and must answer in a fixed JSON shape (enforced by a grammar), which Said turns into Markdown. Long recordings are summarized in parts first, then combined.
  - The model is loaded only while it writes, so it doesn't hold memory the rest of the time.
- **Permissions.** macOS asks for:
  - the microphone;
  - system audio recording, for calls (this isn't screen recording);
  - notifications.

  Said is signed with a local self-signed certificate kept in its own keychain (`~/.said/signing`, with a random password). Because of that, macOS remembers these permissions across updates.
- **Installer.** It builds the newest release tag from source. It remembers which commit each release pointed to, and refuses to install a release that was later rewritten.
- **Links.** `said://start`, `said://stop` and `said://toggle` work from Shortcuts, Raycast or Terminal (`open said://toggle`). Starting always asks for confirmation; stopping doesn't.

## For developers

Build and run:

```bash
./scripts/build-app.sh --open
```

```
Sources/Said/
  SaidApp.swift          menu bar app, URL handling
  MenuView.swift         menu contents
  PillPanel.swift        floating pills: recording and meeting prompt
  Recorder.swift         recording, files, silence and disk warnings
  MeetingDetector.swift  which meeting app is using the mic
  SystemAudioTap.swift   meeting or system audio (Core Audio process tap)
  AudioMixer.swift       mixes mic + call audio into one .m4a
  Transcriber.swift      WhisperKit: model download, transcription
  Summarizer.swift       summary models, download, prompts, writing the summary
  LlamaRunner.swift      llama.cpp: load a GGUF model and generate text
  Notifier.swift         notifications with a Stop button
  Localization.swift     L("…") lookup for translated text
Resources/               Info.plist, icon, en.lproj, pl.lproj
scripts/build-app.sh     builds and signs build/Said.app
scripts/release.sh       cuts a release
scripts/make-icon.swift  draws the app icon
install.sh               the one-line installer
docs/                    website (English + Polish)
```

**Translations.** Text lives in `Resources/<language>.lproj/Localizable.strings`; the keys are the English text from the code. To add a language:

1. Copy `pl.lproj` to `<code>.lproj` and translate it.
2. Add the code to `CFBundleLocalizations` in `Info.plist`.
3. Rebuild.

Pull requests are welcome.

**Releases.** Said uses [SemVer](https://semver.org/).

1. Add a `## [X.Y.Z] - date` section to [CHANGELOG.md](CHANGELOG.md).
2. Run `./scripts/release.sh X.Y.Z`.

The script bumps the version, checks the build, tags, pushes and creates the GitHub release. When you release, also add a short entry to `docs/releases.html` and `docs/pl/releases.html`.

**Ideas for later:**

- labels for who is speaking (“you” vs “others”);
- meeting notes from a local language model;
- a global keyboard shortcut.

## License

MIT
