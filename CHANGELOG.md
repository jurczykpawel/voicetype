# VoiceType Changelog

## [Initial Version] - {PR_MERGE_DATE}

- Toggle Dictation command: record from the mic, transcribe, paste at the cursor.
- Dictation History command: search, re-paste, copy and delete past transcripts.
- Backends: local whisper.cpp (default) and Parakeet v3 (offline), plus cloud OpenAI-compatible (Groq/OpenAI), Deepgram and ElevenLabs Scribe.
- Smart microphone selection: `:default` follows the macOS system default input and skips silent virtual devices (Krisp/Teams/BlackHole/Loopback/RØDE Connect), so recording no longer sticks to a dead index-0 device.
- Anti-hallucination: Silero VAD (auto-downloaded, ~0.9 MB, 200ms speech padding to avoid clipping short words like "w"/"z" at segment edges) skips non-speech audio, a silence guard warns "check your mic" on a dead capture, and a phantom-phrase filter drops known Whisper hallucinations (e.g. "Dziękuję za uwagę.", "Thank you for watching") when they are the entire output — so silence/room-noise no longer pastes phantom text.
- Optional `--format <preset>` post-processing: run the transcript through any OpenAI-compatible chat-completions endpoint (cloud like Groq/OpenAI, or local like Ollama/LM Studio) before pasting — e.g. `--format email` turns free-form dictation into a ready-to-paste email. Presets are plain-text system-prompt files in `~/.voicetype/prompts/`; ships with a default `email` preset. Falls back to the raw transcript on any formatting failure.
- Personal mic override: `VOICETYPE_MIC_PRIORITY`/`VOICETYPE_MIC_AVOID` let you pin a preferred microphone ahead of the macOS system default, and demote another to a last resort — useful when you have multiple inputs (e.g. a desk mic and Bluetooth headset) and don't want macOS's current default to decide.
- Custom vocabulary prompt to bias spelling of names/terms.
- Preferences: backend, language, microphone, custom vocabulary, model path, cloud + Deepgram + ElevenLabs keys, auto-paste.
- 100% local and offline by default — no API, no subscription required.
