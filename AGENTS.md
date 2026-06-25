# AGENTS.md — set up VoiceType with an AI agent

This file is written for an **AI coding agent** (Claude Code, Cursor, Copilot CLI, …) running in
a shell on the user's machine. Goal: install and configure VoiceType end-to-end with as little
human action as possible. Follow it top to bottom; it is idempotent (safe to re-run).

> **What an agent can do:** install dependencies, download the model, place the engine, write
> config, run the installers, verify transcription from the CLI.
> **What only the human can do (GUI):** grant microphone + accessibility permissions, set the
> global hotkey, and on Windows run the AutoHotkey script in their desktop session. Always tell
> the user explicitly when you need them to do one of these, then wait.

Detect the OS first (`uname` → `Darwin` = macOS; otherwise assume Windows/PowerShell) and jump to
the matching section.

---

## macOS

### 1. Dependencies + engine (agent runs this)

Prefer the installer, non-interactively (pick the backend via env — no prompt):

```bash
# parakeet = fast & multilingual; local = whisper.cpp (simplest). Cloud needs only an API key.
VOICETYPE_BACKEND=local VOICETYPE_NO_KM=1 \
  curl -fsSL https://raw.githubusercontent.com/jurczykpawel/voicetype/main/install.sh | bash
```

`VOICETYPE_NO_KM=1` skips the GUI macro import (you'll guide the user through the hotkey yourself).
This installs `ffmpeg` + `whisper-cpp` (Homebrew), downloads the model, and places the engine at
`~/.voicetype/voice-type.sh` (CLI: `voicetype`). If the user has no Homebrew, install it first.

Working from a clone instead? Run `./install.sh` from the repo root — same flags apply.

### 2. Verify transcription works (agent runs this)

```bash
~/.voicetype/voice-type.sh        # start recording
say -v Zosia "test dyktowania"    # feed audio (PL voice; or speak)
~/.voicetype/voice-type.sh        # stop -> should print the transcript
```

If it prints text, the engine works. (On a fresh machine the first `voicetype` may also prompt for
microphone access — see step 3.)

### 3. Permissions — ASK THE USER (you cannot click these)

Tell the user to open **System Settings → Privacy & Security** and enable, for whichever app will
fire the hotkey (Keyboard Maestro Engine or Raycast):
- **Microphone** (recording)
- **Accessibility** (auto-paste via Cmd+V)

### 4. Hotkey (one human click)

- **Keyboard Maestro:** `open keyboard-maestro/voice-type.kmmacros` (from a clone) imports a macro
  pre-bound to Hyper+Space. Or run the installer without `VOICETYPE_NO_KM=1`.
- **Raycast (free):** tell the user to add `~/.voicetype/voice-type.sh` as a Script Command and
  bind a hotkey (e.g. ⌥Space). Enable a Hyper Key in Raycast → Settings → Advanced if desired.

Done: focus any text field → hotkey → speak → hotkey → text is pasted.

---

## Windows (PowerShell)

> Honest note: local transcription is CPU-only on Windows (slower than macOS), and slower still in
> a VM. Use the **parakeet** backend — it's ~10× faster than Whisper on CPU and keeps it usable.

### 1. Dependencies + engine (agent runs this in PowerShell)

```powershell
$env:VOICETYPE_BACKEND = 'parakeet'
irm https://raw.githubusercontent.com/jurczykpawel/voicetype/main/windows/install.ps1 | iex
```

Installs `ffmpeg`, the whisper.cpp bundle (ships `parakeet-cli.exe`), the parakeet model, the
engine at `%USERPROFILE%\.voicetype\voice-type.ps1`, and AutoHotkey. Backend is remembered in a
user env var.

### 2. Verify (agent runs this)

```powershell
# Inject a known wav and run the stop branch, or just confirm the binaries resolve:
& "$env:USERPROFILE\.voicetype\whisper\Release\parakeet-cli.exe" 2>&1 | Select-String 'usage'
ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Select-String '\(audio\)'
```

### 3. Hotkey — ASK THE USER (must run in their desktop session)

A global hotkey can't be armed from a non-interactive/SSH shell. Tell the user to **double-click**
`%USERPROFILE%\.voicetype\voicetype.ahk` (green "H" tray icon appears). Default hotkey:
**Win+Shift+Space** (avoid Ctrl+Alt — it clashes with AltGr on Polish keyboards).

### 4. Permissions — ASK THE USER

Windows Settings → Privacy → **Microphone** → allow desktop apps.

---

## Gotchas an agent should know (so you don't rediscover them)

- **macOS mic device:** the engine uses ffmpeg `:default`; override with `VOICETYPE_MIC=":1"`
  (list: `ffmpeg -f avfoundation -list_devices true -i ""`).
- **Windows recording** uses raw PCM + remux (a killed ffmpeg can't finalize a WAV). The dshow
  device name has spaces → it must stay quoted as one argument.
- **Windows UTF-8:** read whisper/curl output as UTF-8 or Polish diacritics become mojibake.
- **Windows hotkey:** Ctrl+Alt = AltGr on PL layouts and gets swallowed — use Win+Shift+Space.
- **Parakeet on Windows** = whisper.cpp's `parakeet-cli.exe` with `-ng` (force CPU). Model:
  `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` from `ggml-org/parakeet-GGUF`.
- **Backends** (`VOICETYPE_BACKEND`): `local`/`whisper`, `parakeet`, `cloud` (Groq/OpenAI),
  `deepgram`, `elevenlabs`. Cloud needs only a key (no model download) — fastest unattended setup.

---

## Copy-paste prompt for the user

> "Set up VoiceType on my machine using the AGENTS.md in this repo. Detect my OS, install the
> dependencies and the model, place the engine, and verify transcription from the CLI. Tell me
> exactly which buttons to click for microphone/accessibility permissions and the hotkey — do
> everything else yourself."
