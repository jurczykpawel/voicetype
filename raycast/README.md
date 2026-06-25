# VoiceType — Raycast extension

Commands: **Toggle Dictation** (record → transcribe → paste) and **Dictation History**
(search, re-paste, copy, delete past transcripts). Wraps the shared engine in
[`../engine/voice-type.sh`](../engine/voice-type.sh); the build copies it into `assets/`.

Not on the Raycast Store (the Store requires the MIT license; this project is PolyForm
Noncommercial), so you install it as a **local development extension**.

## Install into Raycast

```bash
cd raycast
npm install
npm run dev        # builds + loads the extension into Raycast
```

`Toggle Dictation` and `Dictation History` now appear in Raycast (Settings → Extensions →
VoiceType, under "Development"). Assign a hotkey and grant Raycast **Microphone** +
**Accessibility** permissions. Configure the backend / API keys in the extension preferences.

## What `npm run dev` is (the watcher)

`npm run dev` runs `ray develop` — Raycast's **development mode**. It:

- builds the extension and registers it in Raycast, then
- **stays running and hot-reloads** on every change to `src/` (and re-syncs the engine).

**When to use it:** only while developing/iterating on the extension, or the first time you
load it into Raycast. It's not needed for daily use.

**When to stop it:** any time — press `Ctrl+C` in its terminal. The extension **stays installed**
in Raycast (it just stops auto-rebuilding). Re-run `npm run dev` to resume hot-reload.

**Fully remove the extension:** Raycast → Settings → Extensions → VoiceType → remove.

## Scripts

| Script | What it does |
|---|---|
| `npm run dev` | `ray develop` — load + hot-reload in Raycast (the watcher) |
| `npm run build` | sync engine into `assets/` + `ray build` (one-off production build) |
| `npm run lint` | `ray lint` (note: the Store-only `author`/`license` checks fail by design here) |
| `npm run sync-engine` | copy `../engine/voice-type.sh` → `assets/voice-type.sh` |

## Notes
- For the **Parakeet** backend, install `parakeet-mlx` globally (`pipx install parakeet-mlx`) so
  Raycast finds it on PATH; a project venv won't be visible.
- The bundled engine in `assets/` is regenerated from `../engine/` on every build — edit the
  canonical engine, not the copy.
