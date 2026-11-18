# Changelog

Wersje według [Semantic Versioning](https://semver.org/lang/pl/).

## [0.3.0] - 2026-11-18

- Głosy rozmówców: przy nagraniu spotkania Said nagrywa też dźwięk aplikacji do spotkań (Zoom, Teams, przeglądarka…) i miksuje go z mikrofonem w jeden plik. Działa także na słuchawkach. Używa Core Audio process tap (macOS 14.2+), więc nie potrzebuje uprawnienia do nagrywania ekranu.
- Nowy przełącznik w menu: „Nagrywaj też dźwięk z komputera” dla zwykłych nagrań. Domyślnie wyłączony.
- Skróty URL `said://start`, `said://stop` i `said://toggle`, na przykład dla Skrótów albo Raycasta.
- Poprawka: uprawnienia i schemat URL dopisane w `Info.plist`.

## [0.2.0] - 2026-11-18

- Wykrywanie spotkań: gdy Zoom, Teams, Google Meet (w przeglądarce), Webex, FaceTime, Slack, Discord albo WhatsApp zaczyna używać mikrofonu, Said proponuje nagranie i transkrypcję. Po zakończeniu rozmowy nagranie zatrzymuje się samo. Można to wyłączyć w menu.
- Said pamięta dostęp do mikrofonu po aktualizacjach. Aplikacja jest podpisywana stałym lokalnym certyfikatem, a nie podpisem ad-hoc. Po przejściu na tę wersję macOS zapyta o mikrofon jeszcze tylko raz.
- Transkrypcja nagrania ze spotkania zawiera nazwę aplikacji.

## [0.1.0] - 2026-11-18

Pierwsze wydanie.

- Nagrywanie głosu z paska menu, bez ikony w Docku.
- Mała czarna pastylka na dole ekranu z animacją głosu, czasem i stopem. Można ją przesuwać, a Said zapamiętuje jej miejsce.
- Lokalna transkrypcja (Whisper large-v3 turbo przez WhisperKit), z automatycznym wykrywaniem języka.
- Każde nagranie w osobnym folderze w `~/Music/Said`, razem z transkrypcją w Markdown.
- Instalator w jednej linijce (`install.sh`) i strona projektu.
