<img src="Resources/AppIcon.png" width="96" alt="">

# said

Minimalny, **local-first** rejestrator głosu dla macOS. Żyje w pasku menu, zero internetu, zero chmury.

- Ikona w pasku menu (prawy górny róg) — kliknij **Nagraj**.
- Bez ikony w Docku: Said żyje tylko w pasku menu.
- Na dole ekranu pojawia się mała czarna pastylka z animacją poziomu głosu, licznikiem czasu i przyciskiem stop. Złap i przenieś ją gdzie chcesz, a Said zapamięta to miejsce. Nie kradnie fokusu.
- Podczas nagrywania ikona w pasku zmienia się na ● z czasem.
- Po zakończeniu menu pokazuje tylko podsumowanie: nazwę pliku, czas, rozmiar i **ścieżkę** (Pokaż w Finderze / Kopiuj ścieżkę).

Każde nagranie ma własny folder z plikiem audio (AAC, mono) i transkrypcją:

```
~/Music/Said/2026-11-18_10-15-00/
  said_2026-11-18_10-15-00.m4a
  said_2026-11-18_10-15-00.md
```

## Instalacja

Wklej do Terminala:

```bash
curl -fsSL https://raw.githubusercontent.com/rajanbor/said/main/install.sh | bash
```

Skrypt pobiera kod do `~/.said/src`, buduje aplikację na Twoim Macu i instaluje `Said.app` w `/Applications`. Jeśli nie masz uprawnień do zapisu w `/Applications`, trafia do `~/Applications`. Wymaga macOS 14+ i Xcode Command Line Tools (instalator sam je zaproponuje). Uruchom komendę ponownie, żeby zaktualizować.

Instalator bierze najnowsze wydanie (tag `vX.Y.Z`). Najnowszy kod z `main` albo konkretna wersja:

```bash
curl -fsSL https://raw.githubusercontent.com/rajanbor/said/main/install.sh | SAID_VERSION=main bash
```

Odinstalowanie:

```bash
rm -rf /Applications/Said.app ~/.said "$HOME/Library/Application Support/Said"
```

Strona projektu: https://rajanbor.github.io/said/

## Wykrywanie spotkań

Gdy aplikacja do spotkań zaczyna używać mikrofonu (Zoom, Microsoft Teams, Google Meet w Chrome, Arc, Edge, Brave, Firefox albo Safari, Webex, FaceTime, Slack, Discord, WhatsApp), na dole ekranu pojawia się pastylka „Nagrać i przepisać?”. Kliknij **Nagraj**, a gdy rozmowa się skończy i aplikacja zwolni mikrofon, Said sam zatrzyma nagranie i zrobi transkrypcję. Jeśli nic nie klikniesz, propozycja zniknie po 30 sekundach.

Said sprawdza to przez Core Audio: widzi tylko, który program używa mikrofonu. Nie czyta okien ani kart przeglądarki i nie potrzebuje dodatkowych uprawnień. Dlatego każde użycie mikrofonu w przeglądarce traktuje jak spotkanie. Wykrywanie można wyłączyć w menu.

> Said nagrywa na razie tylko mikrofon. Na słuchawkach głosy rozmówców nie trafią do nagrania. Nagrywanie dźwięku systemowego jest w roadmapie.

## Transkrypcja (lokalna)

Po zakończeniu nagrania Said automatycznie robi transkrypcję modelem **Whisper large-v3 turbo** przez [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML / Neural Engine). Język jest wykrywany automatycznie (polski, angielski i inne). Wynik trafia do folderu nagrania jako Markdown ze znacznikami czasu.

**Jedyny moment, w którym Said korzysta z internetu**, to jednorazowe pobranie modelu (~630 MB z Hugging Face) po kliknięciu **Pobierz model** w menu. Model ląduje w `~/Library/Application Support/Said/Models`. Potem wczytuje się wyłącznie z dysku, z wyłączonym pobieraniem. Pierwsze wczytanie (kompilacja Core ML) może potrwać kilka minut.

> Wbudowany w macOS `SpeechTranscriber` nie obsługuje (jeszcze) polskiego, dlatego użyty jest Whisper.

## Wymagania

- macOS 14+
- Xcode / Command Line Tools ze Swift 5.10+

## Budowanie ze źródeł

```bash
./scripts/build-app.sh --open
```

Skrypt buduje `build/Said.app`. Przy pierwszym nagraniu macOS zapyta o dostęp do mikrofonu.

Aplikacja jest podpisywana lokalnym, samopodpisanym certyfikatem „Said Local Signing”. Trzymany jest w osobnym pęku kluczy `~/.said/signing`, więc systemowy pęk kluczy pozostaje nietknięty. Dzięki temu macOS widzi każdą nową wersję jako tę samą aplikację i pamięta dostęp do mikrofonu. Przy podpisie ad-hoc pytałby po każdej aktualizacji.
Aplikację możesz przenieść do `/Applications`.

## Struktura

```
Sources/Said/
  SaidApp.swift    MenuBarExtra + ikona w pasku
  MenuView.swift   zawartość menu: nagraj/stop + podsumowanie
  PillPanel.swift  pastylki: nagrywanie i propozycja spotkania (NSPanel + SwiftUI)
  Recorder.swift   AVAudioRecorder, metering, ostatnie nagranie
  Transcriber.swift  WhisperKit: pobranie modelu, transkrypcja → .md
  MeetingDetector.swift  który program do spotkań używa mikrofonu (Core Audio)
Resources/          Info.plist, AppIcon.icns
scripts/build-app.sh   buduje build/Said.app
scripts/make-icon.swift  generuje ikonę
scripts/release.sh     nowe wydanie (tag + GitHub release)
install.sh          instalator (curl | bash)
docs/               strona www (GitHub Pages)
```

## Wersje

Numeracja według [SemVer](https://semver.org/lang/pl/), historia zmian w [CHANGELOG.md](CHANGELOG.md). Wersja jest widoczna na dole menu aplikacji.

Nowe wydanie: dopisz sekcję `## [X.Y.Z] - data` w `CHANGELOG.md`, a potem uruchom:

```bash
./scripts/release.sh X.Y.Z
```

Skrypt podbija wersję w `Info.plist`, sprawdza, czy aplikacja się buduje, tworzy commit i tag `vX.Y.Z`, wypycha je i tworzy wydanie na GitHubie.

## Roadmapa (pomysły)

- Rozróżnianie mówców (diarization)
- Notatka Markdown (np. do Obsidiana) generowana lokalnym LLM (Ollama)
- Nagrywanie audio systemowego (ScreenCaptureKit) dla spotkań online
- Globalny skrót klawiszowy

Pamiętaj, by informować rozmówców o nagrywaniu.

## Licencja

MIT
