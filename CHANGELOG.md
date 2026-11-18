# Changelog

Wersje według [Semantic Versioning](https://semver.org/lang/pl/).

## [0.1.0] - 2026-11-18

Pierwsze wydanie.

- Nagrywanie głosu z paska menu, bez ikony w Docku.
- Mała czarna pastylka na dole ekranu z animacją głosu, czasem i stopem. Można ją przesuwać, a Said zapamiętuje jej miejsce.
- Lokalna transkrypcja (Whisper large-v3 turbo przez WhisperKit), z automatycznym wykrywaniem języka.
- Każde nagranie w osobnym folderze w `~/Music/Said`, razem z transkrypcją w Markdown.
- Instalator w jednej linijce (`install.sh`) i strona projektu.
