# said

Minimalny, **local-first** rejestrator głosu dla macOS. Żyje w pasku menu, zero internetu, zero chmury.

- Ikona w pasku menu (prawy górny róg) — kliknij **Nagraj**.
- Na środku ekranu pojawia się pływająca pastylka z animacją poziomu głosu, licznikiem czasu i przyciskiem stop. Można ją przeciągnąć; nie kradnie fokusu.
- Podczas nagrywania ikona w pasku zmienia się na ● z czasem.
- Po zakończeniu menu pokazuje tylko podsumowanie: nazwę pliku, czas, rozmiar i **ścieżkę** (Pokaż w Finderze / Kopiuj ścieżkę).

Nagrania trafiają do `~/Music/Said/said_RRRR-MM-DD_GG-MM-SS.m4a` (AAC, mono). Aplikacja nie wykonuje żadnych połączeń sieciowych.

## Wymagania

- macOS 14+
- Xcode / Command Line Tools ze Swift 5.10+

## Budowanie

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
Resources/Info.plist
scripts/build-app.sh
```

## Roadmapa (pomysły)

- Lokalna transkrypcja (WhisperKit / FluidAudio – Parakeet) po zakończeniu nagrania
- Rozróżnianie mówców (diarization)
- Notatka Markdown (np. do Obsidiana) generowana lokalnym LLM (Ollama)
- Nagrywanie audio systemowego (ScreenCaptureKit) dla spotkań online
- Globalny skrót klawiszowy

Pamiętaj, by informować rozmówców o nagrywaniu.

## Licencja

MIT
