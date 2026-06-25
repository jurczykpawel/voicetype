# VoiceType 🎙️

**Free, fully local dictation for macOS.** Press a hotkey, speak, press again — your words
are transcribed on-device with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and
pasted at the cursor. A self-hosted alternative to SuperWhisper: no subscription, no API,
no cloud, works offline.

Two ways to drive it, same engine:

- **Keyboard Maestro** — global Hyper+Space hotkey (toggle).
- **Raycast** — `Toggle Dictation` + `Dictation History` commands.

## Install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/jurczykpawel/voicetype/main/install.sh | bash
```

The installer:
1. checks Homebrew and installs `ffmpeg` + `whisper-cpp` if missing,
2. downloads the `large-v3-turbo` model (~1.5 GB, one-time),
3. installs the engine to `~/.voicetype/voice-type.sh` (CLI: `voicetype`),
4. imports the Keyboard Maestro macro (if KM is installed), pre-bound to **Hyper+Space**.

Then grant permissions in **System Settings → Privacy & Security**:
- **Microphone** → Keyboard Maestro Engine (recording)
- **Accessibility** → Keyboard Maestro Engine (auto-paste)

`Hyper` = Caps Lock remapped to ⌃⌥⌘⇧ (via Karabiner-Elements or the Hyperkey app).

## How it works

```
hotkey ─▶ ffmpeg records mic ─▶ hotkey again ─▶ whisper.cpp transcribes ─▶ clipboard ─▶ Cmd+V at cursor
```

The whole pipeline is one shell script, [`engine/voice-type.sh`](engine/voice-type.sh) — a
stateful toggle (lockfile-tracked `ffmpeg` PID). Transcription with `large-v3-turbo` on
Apple Silicon takes ~1–2 s for short dictation.

## Configuration

Set env vars in the Keyboard Maestro action, your shell, or Raycast preferences:

| Variable | Default | Description |
|---|---|---|
| `VOICETYPE_LANG` | `pl` | language code (`auto` = autodetect) |
| `VOICETYPE_MIC` | `:default` | ffmpeg avfoundation device, e.g. `:1` (`ffmpeg -f avfoundation -list_devices true -i ""`) |
| `VOICETYPE_MODEL` | `~/.local/share/whisper-cpp/ggml-large-v3-turbo.bin` | path to any ggml model |
| `VOICETYPE_PROMPT` | — | initial prompt / custom vocabulary (proper nouns, terms) |
| `VOICETYPE_PASTE` | `1` | `0` = clipboard only, no auto-paste |

## Repository layout

```
voicetype/
├── install.sh              # one-liner installer
├── engine/voice-type.sh    # the core (canonical) — toggle record → transcribe → paste
├── keyboard-maestro/        # importable .kmmacros (Hyper+Space)
└── raycast/                 # Raycast extension (Toggle Dictation + Dictation History)
```

## Raycast extension (dev)

```bash
cd raycast
npm install
npm run dev          # syncs engine into assets/ and loads into Raycast
```
Bind **Toggle Dictation** to a hotkey in Raycast and grant Raycast Microphone +
Accessibility permissions. Note: the official Raycast Store requires the MIT license, so
this extension is distributed here directly (not via the Store).

## License

**[PolyForm Noncommercial 1.0.0](LICENSE)** — free for personal and noncommercial use.
Commercial use requires a license — contact [@jurczykpawel](https://github.com/jurczykpawel).

Required Notice: Copyright © 2026 Paweł Jurczyk.
