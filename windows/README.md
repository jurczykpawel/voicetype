# VoiceType on Windows

A PowerShell port of the engine + an AutoHotkey hotkey. Same idea as macOS: press a hotkey,
speak, press again — transcribe and paste at the cursor.

> **Status: tested on real Windows 11** (PowerShell 5.1, in a Parallels VM) — live dictation
> works end-to-end (record → transcribe → paste), Polish UTF-8 correct.

## Backends
- **Parakeet** _(recommended)_ — `parakeet-cli.exe` (ships inside the whisper.cpp bundle) + a
  multilingual ggml model. **~10× faster than Whisper on CPU** (sub-second to ~2 s vs tens of
  seconds), auto-detects language. This is what makes local dictation usable on Windows.
- **Whisper** — `whisper-cli.exe` + a ggml model. Higher RAM/CPU cost; slow on CPU-only/VMs.
- **Cloud** — OpenAI-compatible (Groq is free / OpenAI), **Deepgram**, **ElevenLabs Scribe**.
  Uses the built-in `curl.exe` (Win 10/11) and native `ConvertFrom-Json` — no extra deps.

> **Performance note:** local transcription on Windows is **not as snappy as on Apple Silicon**.
> The Mac uses Metal/ANE; on Windows it's CPU-only (and even more so inside a Parallels VM, with
> no usable GPU passthrough). Parakeet keeps it usable; Whisper-large on CPU can take tens of
> seconds. On real Windows hardware (especially with an NVIDIA GPU build) it's faster.

## Why AutoHotkey (not PowerToys)
PowerToys has no "press a hotkey → run my command" feature (Keyboard Manager only remaps keys;
PowerToys Run is a typed launcher). **AutoHotkey v2** is purpose-built for a global hotkey that
runs a script, so it's the right tool here.

## Install (one-liner)

```powershell
irm https://raw.githubusercontent.com/jurczykpawel/voicetype/main/windows/install.ps1 | iex
```

Asks which backend to set up (Parakeet by default), installs `ffmpeg` + the whisper.cpp bundle
and the matching model, drops the engine in `%USERPROFILE%\.voicetype\`, installs AutoHotkey, and
remembers your backend in a user env var.

Then:
1. Run `%USERPROFILE%\.voicetype\voicetype.ahk` (copy it to `shell:startup` to autostart).
2. Press **Win+Shift+Space** to start, again to stop + paste. (Change the hotkey at the top of the `.ahk`.)
3. Cloud backend? Set a key: `setx GROQ_API_KEY gsk_...` (or `VOICETYPE_DEEPGRAM_KEY` / `VOICETYPE_ELEVENLABS_KEY`).

## Config (user env vars)

Same `VOICETYPE_*` variables as the macOS engine. Set persistently with `setx`, e.g.:

```powershell
setx VOICETYPE_BACKEND cloud
setx VOICETYPE_LANG en
setx VOICETYPE_MIC "Microphone (Realtek(R) Audio)"   # exact dshow device name
```

List microphone names: `ffmpeg -hide_banner -list_devices true -f dshow -i dummy`

## Files
- `voice-type.ps1` — engine (toggle record → transcribe → paste)
- `voicetype.ahk` — global hotkey (Win+Shift+Space) that runs the engine
- `install.ps1` — installer

## Implementation notes (learned from testing)
- **Recording uses raw PCM** (`-f s16le`) and remuxes to WAV on stop — WAV needs end-of-file
  finalization that a killed ffmpeg can't do, so we avoid it entirely (a hard kill on raw PCM is safe).
- **Mic auto-detect** runs `ffmpeg -list_devices` via `Start-Process -RedirectStandardError`,
  because a console-less child (launched by AHK) gets no output from a plain `& ffmpeg 2>&1`.
- The dshow device name (with spaces) is passed quoted as a single argument.
- whisper/curl output is read as **UTF-8** so Polish diacritics survive PowerShell 5.1's ANSI default.
- The release ships `whisper-cli.exe` (real) and `main.exe` (deprecation stub) — use the former.

## Notes
- Parakeet has no language flag (it auto-detects); `VOICETYPE_LANG` only affects Whisper/cloud.
- `SendKeys ^v` paste timing across apps works in practice; tune if a target app misses the paste.
