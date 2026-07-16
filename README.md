# VoiceType 🎙️

**Free, fully local dictation for macOS** (Windows: [beta](windows/)). Press a hotkey,
speak, press again — your words are transcribed on-device with
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) and pasted at the cursor. A self-hosted
alternative to SuperWhisper: no subscription, no API, no cloud, works offline.

Two ways to drive it, same engine:

- **Keyboard Maestro** — global Hyper+Space hotkey (toggle).
- **Raycast** — `Toggle Dictation` + `Dictation History` commands.

## Install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/jurczykpawel/voicetype/main/install.sh | bash
```

> **Prefer to let an AI agent set it up?** Point Claude Code / Cursor at [`AGENTS.md`](AGENTS.md) —
> it's a deterministic runbook (macOS + Windows) the agent can execute, doing everything except the
> few GUI clicks (permissions + hotkey) it will explicitly ask you for.

The installer **asks which backend you want**:

1. **Whisper** — local, offline; installs `whisper-cpp` + downloads the `large-v3-turbo` model (~1.5 GB). _(default)_
2. **Parakeet v3** — local, offline, multilingual; installs `parakeet-mlx`.
3. **Cloud only** — installs nothing heavy, **no model download**; you add an API key later.
4. **All local** — Whisper + Parakeet.

It always installs `ffmpeg` + `jq`, drops the engine at `~/.voicetype/voice-type.sh` (CLI: `voicetype`),
saves your choice to `~/.voicetype/config`, and imports the Keyboard Maestro macro (if KM is installed),
pre-bound to **Hyper+Space**.

Non-interactive / scripted? Skip the prompt with an env var:

```bash
curl -fsSL https://raw.githubusercontent.com/jurczykpawel/voicetype/main/install.sh | VOICETYPE_BACKEND=cloud bash
```

Then grant permissions in **System Settings → Privacy & Security**:
- **Microphone** → Keyboard Maestro Engine (recording)
- **Accessibility** → Keyboard Maestro Engine (auto-paste)

`Hyper` = Caps Lock remapped to ⌃⌥⌘⇧. Easiest: enable it right in **Raycast → Settings →
Advanced → Hyper Key** (no extra tools). Alternatives: Karabiner-Elements or the Hyperkey app.

## How it works

```
hotkey ─▶ ffmpeg records mic ─▶ hotkey again ─▶ whisper.cpp transcribes ─▶ clipboard ─▶ Cmd+V at cursor
```

The whole pipeline is one shell script, [`engine/voice-type.sh`](engine/voice-type.sh) — a
stateful toggle (lockfile-tracked `ffmpeg` PID). Transcription with `large-v3-turbo` on
Apple Silicon takes ~1–2 s for short dictation.

## Transcription backends

Pick the engine that fits — set `VOICETYPE_BACKEND` (or the **Backend** dropdown in Raycast).
Local backends are private, offline and free; cloud backends need an API key.

| Backend | `VOICETYPE_BACKEND` | Cost | Notes |
|---|---|---|---|
| **whisper.cpp** (default) | `local` | free, offline | Strong multilingual (PL+EN), simple CLI |
| **Parakeet v3** | `parakeet` | free, offline | Multilingual auto-detect (25 EU langs incl. PL), great on natural speech |
| **OpenAI-compatible** | `cloud` | Groq free / OpenAI paid | Works with [Groq](https://console.groq.com), OpenAI, or any compatible server |
| **Deepgram** | `deepgram` | paid | Nova-3, low latency; `language=multi` when lang is `auto` |
| **ElevenLabs Scribe** | `elevenlabs` | paid | Strong multilingual accuracy |

```bash
# Free cloud (Groq) — OpenAI-compatible
export VOICETYPE_BACKEND=cloud  VOICETYPE_CLOUD_KEY=gsk_...      # or GROQ_API_KEY / OPENAI_API_KEY

# OpenAI instead of Groq
export VOICETYPE_BACKEND=cloud \
       VOICETYPE_CLOUD_URL=https://api.openai.com/v1/audio/transcriptions \
       VOICETYPE_CLOUD_MODEL=gpt-4o-transcribe  VOICETYPE_CLOUD_KEY=sk-...

# Deepgram / ElevenLabs (need jq: brew install jq)
export VOICETYPE_BACKEND=deepgram    VOICETYPE_DEEPGRAM_KEY=...
export VOICETYPE_BACKEND=elevenlabs  VOICETYPE_ELEVENLABS_KEY=...
```

Google (Gemini) and Microsoft (Azure Speech) use non-OpenAI APIs and aren't wired in yet — roadmap.

### Local Parakeet (optional)

```bash
pipx install parakeet-mlx        # or: pip install parakeet-mlx
export VOICETYPE_BACKEND=parakeet
```

Benchmarked on an M4 (Polish): accuracy is on par with whisper-large-v3-turbo, and both finish
short dictation in ~1–2 s. Parakeet's headline ~80 ms latency needs a resident model (CoreML
daemon) — a future upgrade; the per-invocation CLI here reloads the model each call like Whisper.

## Custom vocabulary

Bias spelling of names, brands and jargon with an initial prompt (local + OpenAI-compatible cloud):

```bash
export VOICETYPE_PROMPT="Raycast, whisper.cpp, Jurczyk, ReelStack, PostStack"
```

In Raycast it's the **Custom vocabulary** preference.

## Configuration

Set env vars in the Keyboard Maestro action, your shell, or Raycast preferences:

| Variable | Default | Description |
|---|---|---|
| `VOICETYPE_BACKEND` | `local` | `local` \| `parakeet` \| `cloud` \| `deepgram` \| `elevenlabs` |
| `VOICETYPE_LANG` | `pl` | language code (`auto` = autodetect) |
| `VOICETYPE_MIC` | `:default` | avfoundation device. `:default` follows the macOS system default input, skipping silent virtual devices (Krisp/Teams/BlackHole/Loopback/RØDE Connect). Force one with an index `:1` or name `:MacBook Pro Microphone` (list: `ffmpeg -f avfoundation -list_devices true -i ""`) |
| `VOICETYPE_MIC_PRIORITY` | — | personal: `;`-separated substrings, checked in priority order before the system default. First currently-connected match wins |
| `VOICETYPE_MIC_AVOID` | — | personal: `;`-separated substrings for devices used only as a last resort (e.g. a Bluetooth headset) |
| `VOICETYPE_PROMPT` | — | initial prompt / custom vocabulary (proper nouns, terms) |
| `VOICETYPE_FORMAT` | — | formatting preset to run the transcript through after transcription (e.g. `email`); same as passing `--format <name>` on the CLI |
| `VOICETYPE_PASTE` | `1` | `0` = clipboard only, no auto-paste |
| `VOICETYPE_MODEL` | `~/.local/share/whisper-cpp/ggml-large-v3-turbo.bin` | local: path to any ggml model |
| `VOICETYPE_VAD_MODEL` | `~/.local/share/whisper-cpp/ggml-silero-v5.1.2.bin` | local: Silero VAD model (auto-downloaded, ~0.9 MB) — skips non-speech so Whisper can't hallucinate phantom phrases on silence |
| `VOICETYPE_PARAKEET_MODEL` | `mlx-community/parakeet-tdt-0.6b-v3` | parakeet: HF model repo |
| `VOICETYPE_CLOUD_URL` | Groq transcriptions URL | cloud: OpenAI-compatible endpoint |
| `VOICETYPE_CLOUD_MODEL` | `whisper-large-v3-turbo` | cloud: transcription model |
| `VOICETYPE_CLOUD_KEY` | — | cloud: API key (falls back to `GROQ_API_KEY`, then `OPENAI_API_KEY`) |
| `VOICETYPE_DEEPGRAM_KEY` | — | deepgram: API key (falls back to `DEEPGRAM_API_KEY`) |
| `VOICETYPE_DEEPGRAM_MODEL` | `nova-3` | deepgram: model |
| `VOICETYPE_ELEVENLABS_KEY` | — | elevenlabs: API key (falls back to `ELEVENLABS_API_KEY`) |
| `VOICETYPE_ELEVENLABS_MODEL` | `scribe_v1` | elevenlabs: model |
| `VOICETYPE_FORMAT_URL` | Groq chat/completions URL | format: any OpenAI-compatible `/chat/completions` endpoint — cloud (Groq, OpenAI) or local (Ollama, LM Studio) |
| `VOICETYPE_FORMAT_MODEL` | fast Groq Llama model | format: model name |
| `VOICETYPE_FORMAT_KEY` | — | format: API key (falls back to `VOICETYPE_CLOUD_KEY`, then `GROQ_API_KEY`, then `OPENAI_API_KEY`). Leave empty for keyless local servers |
| `VOICETYPE_PROMPTS_DIR` | `~/.voicetype/prompts` | format: directory of preset files (see below) |

## Formatting presets

Dictate free-form and get it auto-formatted before pasting — e.g. turn rambling speech into a
ready-to-send email. Opt-in, zero cost/latency when unused:

```bash
voicetype --format email
```

A preset is a plain text file, `~/.voicetype/prompts/<name>.txt`, whose entire content is the
system prompt sent to the LLM along with your transcript. The installer seeds a default
`email.txt` (never overwriting an existing, possibly edited, copy). Add your own — `slack.txt`,
`notatka.txt`, whatever — no code changes needed.

The formatting call goes to any OpenAI-compatible `/chat/completions` endpoint — cloud (Groq by
default, or OpenAI) or local (Ollama, LM Studio: just point `VOICETYPE_FORMAT_URL` at your local
server and leave the key empty). If the call fails for any reason, the raw transcript is pasted
instead (with a warning) — you never lose what you said. An unknown preset name aborts instead,
since that's a config mistake rather than a transient failure.

**Binding it to its own hotkey:** in Raycast, use the separate **"Toggle Dictation — Email"**
command (its own slot in Raycast Settings → Hotkey). In Keyboard Maestro, duplicate your existing
dictation macro, give it a new trigger, and change its shell command to pass `--format email`. On
Windows, `voicetype.ahk` already ships a second hotkey, **Win+Shift+E**, for exactly this.

## Windows (beta)

A PowerShell port lives in [`windows/`](windows/) — local **Parakeet** (recommended, fast) and
Whisper, plus cloud (Groq/OpenAI/Deepgram/ElevenLabs), driven by an AutoHotkey hotkey
(Win+Shift+Space, or Win+Shift+E to dictate straight into an `--format email`). Also supports the
same `VOICETYPE_FORMAT`/`VOICETYPE_FORMAT_URL`/`VOICETYPE_FORMAT_MODEL`/`VOICETYPE_FORMAT_KEY`/
`VOICETYPE_PROMPTS_DIR` env vars as macOS — see [Formatting presets](#formatting-presets) above.
Validated end-to-end on Windows 11. Parakeet uses whisper.cpp's
`parakeet-cli.exe` (CPU) — much faster than Whisper there. Local transcription is CPU-only on
Windows, so not as snappy as on Apple Silicon. See [`windows/README.md`](windows/README.md).

```powershell
irm https://raw.githubusercontent.com/jurczykpawel/voicetype/main/windows/install.ps1 | iex
```

## Repository layout

```
voicetype/
├── install.sh              # macOS one-liner installer
├── engine/voice-type.sh    # the core (canonical) — toggle record → transcribe → paste
├── keyboard-maestro/        # importable .kmmacros (Hyper+Space)
├── raycast/                 # Raycast extension (Toggle Dictation + Dictation History)
└── windows/                 # PowerShell engine + AutoHotkey hotkey + install.ps1 (experimental)
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

## Support

VoiceType is free and always will be — no trial, no cloud, no subscription. If it
saved you from paying for yet another dictation app, you can buy me a coffee:

[![☕ Buy me a coffee](https://img.shields.io/badge/☕_Buy_me_a_coffee-FFDD00)](https://sellf.techskills.academy/checkout/tip-voicetype?utm_source=github&utm_medium=readme&utm_campaign=tip-jar)

## License

**[PolyForm Noncommercial 1.0.0](LICENSE)** — free for personal and noncommercial use.
Commercial use requires a license — contact [@jurczykpawel](https://github.com/jurczykpawel).

Required Notice: Copyright © 2026 Paweł Jurczyk.
