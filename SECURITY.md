# Security

Said records conversations, so it's built to keep them on your Mac and to never record without you knowing.

## Reporting a problem

Please report security issues privately through GitHub's
[security advisories](https://github.com/rajanbor/said/security/advisories/new), not as a public issue.

## What Said does to protect you

**Recording only starts when you start it.**
- You start recording from the menu, or by clicking **Record** in the pill.
- `said://start` and `said://toggle`, which any app or web page can open, don't record. They show a “Start recording?” pill that you have to click. The pill ignores clicks for its first 0.7 s, so a click aimed at something else can't land on it.
- `said://stop` works without confirmation, because it can only end a recording.
- While recording, the pill is on screen and the menu bar icon shows ● and a timer.

**It records only what you expect.**
- A meeting recording captures your microphone plus the audio of that one meeting app.
- If Said can't find that app's audio, it records the microphone only and says so. It never widens to everything the Mac plays.
- Recording everything the Mac plays happens only when you turn on **Record system audio** yourself.

**Nothing leaves your Mac.**
- Transcription runs locally on the Neural Engine and GPU.
- The model is downloaded once, when you click the button. After that it loads with downloads switched off.
- Said has no analytics, no accounts and no server.

**Recordings are private to your user account.**
- `~/Music/Said` and each recording folder are `0700`; audio and transcripts are `0600`.
- Older recordings are covered too, because Said locks the parent folder on launch.

**No silent data loss.**
- Temporary tracks are deleted only after the final file is confirmed playable.
- If mixing or saving fails, the tracks are kept as visible files.
- Said stops and saves before the disk fills up.

**Signing key.** The local code-signing key lives in its own keychain, `~/.said/signing`:
- the keychain is protected by a random password, stored in a `0600` file;
- the folder is `0700`;
- the unencrypted key exists only in a temporary folder that's removed on any exit;
- keychains from Said 0.4.0 and earlier, which used a fixed password, are switched to a random one automatically on the next build.

**Installer.**
- It builds from source on your Mac, with dependencies pinned in `Package.resolved`.
- It remembers which commit each release tag pointed to (`~/.said/known-releases`). If an installed release is later rewritten to point elsewhere, it refuses to install.
- It prints the commit it builds.

## Known limits

**Same-user access.** Other apps running as your user can read your files, including recordings. Said isn't sandboxed, because it needs Core Audio process taps. Use FileVault to encrypt the disk.

**Browser audio.** Tapping a browser captures all of that browser's tabs, not just the meeting tab. For Safari, audio goes through `com.apple.WebKit.GPU`, which is shared by every app that plays audio through WebKit (Safari, Mail, …).

**No Apple notarization.** Said is signed with a local self-signed certificate. That keeps permissions stable across updates, but unlike Apple's Developer ID it doesn't prove who built the app.

**Trust on first use.** The installer's tag check protects updates. It can't protect the very first install, and it can't stop someone who controls the repository from publishing a new, malicious tag. Protected tags and branches on GitHub reduce that risk.

**Shortcuts.** Starting from Shortcuts or Raycast now needs one click on the pill.
