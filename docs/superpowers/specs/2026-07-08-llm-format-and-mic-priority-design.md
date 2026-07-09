# Design: LLM post-formatting (`--format`) + personal mic priority

Date: 2026-07-08

## 1. LLM post-formatting

### Goal
Dictate free-form speech and get it auto-formatted (e.g. into a ready-to-paste
email) before it's copied/pasted, using any OpenAI-compatible chat-completions
endpoint (cloud like Groq/OpenAI, or local like Ollama/LM Studio).

### CLI / config surface
- New CLI arg: `--format <name>` (first real argv parsing this engine gets;
  today it's 100% env-var driven). Absent = today's behavior, zero change,
  zero added latency/cost.
- `VOICETYPE_FORMAT` — env-var equivalent of `--format`, for setting a
  persistent default in `~/.voicetype/config`. CLI arg wins if both given.
- `VOICETYPE_FORMAT_URL` — chat/completions endpoint
  (default: `https://api.groq.com/openai/v1/chat/completions`).
- `VOICETYPE_FORMAT_MODEL` — model name (default: a fast Groq Llama model).
- `VOICETYPE_FORMAT_KEY` — key; fallback chain
  `VOICETYPE_FORMAT_KEY → VOICETYPE_CLOUD_KEY → GROQ_API_KEY → OPENAI_API_KEY`.
  Empty key = no `Authorization` header (for keyless local servers).
- `VOICETYPE_PROMPTS_DIR` — preset directory (default `~/.voicetype/prompts`).
- Preset = plain text file, `<PROMPTS_DIR>/<name>.txt`, whole content is the
  system prompt. Repo ships `prompts/email.txt`; installer copies it to
  `~/.voicetype/prompts/email.txt` only if the file doesn't already exist
  (never overwrites a user's edits — same idiom as model/VAD auto-download).

### Data flow
1. START: if `--format`/`VOICETYPE_FORMAT` set, persist the name to
   `$WORKDIR/format` (same idiom as the existing `$WORKDIR/mic` persistence
   for the chosen microphone).
2. STOP (triggered by *either* hotkey): after transcription + existing
   silence-guard + phantom-filter (unchanged), read `$WORKDIR/format` from
   the START call — not from the stopping invocation's own args/env — so
   stopping with the "normal" hotkey still applies formatting chosen at
   start.
3. Empty format → old code path, unchanged.
4. Non-empty format → `format_llm "$TEXT" "$FORMAT"`:
   - Missing preset file → notify `❌ nieznany format: $FORMAT`, abort
     (paste nothing) — this is a config error, not a transient failure.
   - `need_jq` (existing helper, already used by deepgram/elevenlabs).
   - POST `$VOICETYPE_FORMAT_URL` with
     `messages=[{role:system, content:<preset file content>}, {role:user, content:$TEXT}]`,
     `model=$VOICETYPE_FORMAT_MODEL`, 15s timeout.
   - Parse `.choices[0].message.content` via `jq`.
   - Strip a leading/trailing ``` fence defensively, in case the model
     ignores the "output only the final text" instruction in the prompt.
5. LLM call fails (no key/network/timeout/bad JSON) → **fallback to the raw
   transcript** + notify `⚠️ formatowanie nieudane — wklejono surowy tekst`.
   Never lose what was said.
6. Result (formatted or raw-fallback) continues through the existing
   pbcopy → auto-paste (respecting `PASTE`) → notification path, unchanged.

### Scope
Applies to the OSS `voicetype` engine only (macOS `engine/voice-type.sh` +
its 3 synced copies, and `windows/voice-type.ps1`). Explicitly **out of
scope**: the paid "Dyktowanie AI bez abonamentu" lead magnet — different
product, different audience, not requested.

### Frontend wiring
- Raycast: new command "Toggle Dictation — Email" (own hotkey slot in
  Raycast Settings), calls the engine with `--format email`.
- Windows AHK: second hotkey line calling the engine with `--format email`.
- Keyboard Maestro: documented in README as a manual step (personal GUI
  config, not part of the repo) — duplicate the existing macro, change the
  trigger and the shell command to pass `--format email`.

## 2. Personal mic priority (Pawel's machine only)

### Goal
On Pawel's Mac specifically: always prefer the RØDE PodMic USB mic when
connected, regardless of macOS's current system-default input, and treat
the WH-1000XM4 Bluetooth headset mic as an absolute last resort.

### Mechanism (generic, ships in the public repo)
Two new env vars, checked in `resolve_auto_mic()` **before** the existing
system-default logic:
- `VOICETYPE_MIC_PRIORITY` — semicolon-separated, ordered list of
  case-insensitive substrings. The first substring that matches a
  currently-connected avfoundation input device wins, overriding whatever
  macOS considers the system default.
- `VOICETYPE_MIC_AVOID` — semicolon-separated substrings for devices to
  demote to last resort: excluded from every normal resolution step (system
  default, built-in fallback, first non-virtual), only used if literally
  nothing else matches.

No hardware names are hardcoded in the shared script — it stays
device-agnostic, consistent with the existing `VOICETYPE_MIC` design.

### Pawel's personal values (his local `~/.voicetype/config`, not in git)
```bash
VOICETYPE_MIC_PRIORITY="PodMic"
VOICETYPE_MIC_AVOID="WH-1000XM4"
```
Confirmed via `ffmpeg -f avfoundation -list_devices true -i ""` on his
machine: `[6] RØDE PodMic USB` is his real hardware RØDE mic (the other
`RØDE Connect *` entries are virtual/software and already excluded by the
existing `VIRT_RE` pattern); `[1] WH-1000XM4` is the Bluetooth headset.

### Scope
Engine change (both platforms use the same avfoundation-device-name
matching approach on macOS; Windows dshow mic picking is unaffected since
Pawel's request is macOS-specific — no change needed to
`windows/voice-type.ps1` mic logic).
