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

Odinstalowanie:

```bash
rm -rf /Applications/Said.app ~/.said "$HOME/Library/Application Support/Said"
```

Strona projektu: https://rajanbor.github.io/said/

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

Skrypt buduje `build/Said.app` (podpis ad-hoc). Przy pierwszym nagraniu macOS zapyta o dostęp do mikrofonu.
Aplikację możesz przenieść do `/Applications`.

## Struktura

```
Sources/Said/
  SaidApp.swift    MenuBarExtra + ikona w pasku
  MenuView.swift   zawartość menu: nagraj/stop + podsumowanie
  PillPanel.swift  pływająca pastylka (NSPanel + SwiftUI)
  Recorder.swift   AVAudioRecorder, metering, ostatnie nagranie
  Transcriber.swift  WhisperKit: pobranie modelu, transkrypcja → .md
Resources/          Info.plist, AppIcon.icns
scripts/build-app.sh   buduje build/Said.app
scripts/make-icon.swift  generuje ikonę
install.sh          instalator (curl | bash)
docs/               strona www (GitHub Pages)
```

## Roadmapa (pomysły)

- Rozróżnianie mówców (diarization)
- Notatka Markdown (np. do Obsidiana) generowana lokalnym LLM (Ollama)
- Nagrywanie audio systemowego (ScreenCaptureKit) dla spotkań online
- Globalny skrót klawiszowy

Pamiętaj, by informować rozmówców o nagrywaniu.

## Licencja

MIT
