# VoiceType (Raycast)

Free, **fully local** dictation for macOS — a Raycast-native alternative to SuperWhisper.
Press the hotkey to record, press again to transcribe (whisper.cpp) and paste at your cursor.
No subscription, no API, no internet.

> Product seed. Core engine lives in `assets/voice-type.sh` (shared with the Keyboard Maestro
> setup in `scripts/media/`). MVP wraps the shell engine; roadmap is a native TS implementation.

## Requirements
```bash
brew install ffmpeg whisper-cpp
# grab a model, e.g. large-v3-turbo, into ~/.local/share/whisper-cpp/
```

## Dev
```bash
cd projects/voicetype-raycast
npm install
npm run dev        # loads into Raycast in development
```
Then bind **Toggle Dictation** to a hotkey in Raycast (Settings → Extensions → VoiceType).

## Permissions
Grant **Raycast** access to **Microphone** and **Accessibility** (System Settings → Privacy & Security).

## Preferences
Language · Microphone (`:default` / `:1`) · Model path · Auto-paste toggle.

## Roadmap to a sellable product
- [ ] Native TS record (avfoundation via node) + transcription (whisper.cpp bindings) — drop bash dependency
- [ ] Recording HUD with live timer / waveform
- [ ] Transcript history command (searchable, re-paste)
- [ ] Custom vocabulary / prompt presets per app
- [ ] Bundled model download/management
- [ ] Icon + Store listing + screenshots
