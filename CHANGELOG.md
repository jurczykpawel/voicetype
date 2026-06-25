# VoiceType Changelog

## [Initial Version] - {PR_MERGE_DATE}

- Toggle Dictation command: record from the mic, transcribe, paste at the cursor.
- Dictation History command: search, re-paste, copy and delete past transcripts.
- Backends: local whisper.cpp (default) and Parakeet v3 (offline), plus cloud OpenAI-compatible (Groq/OpenAI), Deepgram and ElevenLabs Scribe.
- Custom vocabulary prompt to bias spelling of names/terms.
- Preferences: backend, language, microphone, custom vocabulary, model path, cloud + Deepgram + ElevenLabs keys, auto-paste.
- 100% local and offline by default — no API, no subscription required.
