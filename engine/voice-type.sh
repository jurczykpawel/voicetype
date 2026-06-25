#!/bin/bash
# voice-type.sh — darmowy odpowiednik SuperWhisper, w 100% lokalnie (whisper.cpp + ffmpeg).
#
# TOGGLE: pierwsze wywołanie = start nagrywania mikrofonu.
#         drugie wywołanie  = stop -> transkrypcja -> tekst do schowka -> auto-wklejenie w miejsce kursora.
#
# Pomyślane jako jeden silnik dla wielu frontendów (Keyboard Maestro hotkey, Raycast, CLI).
#
# Konfiguracja przez zmienne środowiskowe (wszystkie opcjonalne):
#   VOICETYPE_MODEL   ścieżka do modelu ggml (domyślnie large-v3-turbo)
#   VOICETYPE_LANG    język (domyślnie pl; 'auto' = autodetekcja)
#   VOICETYPE_MIC     urządzenie ffmpeg avfoundation, np. ":1" lub ":default" (domyślnie :default)
#   VOICETYPE_PROMPT  initial prompt dla whispera (słownik nazw własnych, terminów)
#   VOICETYPE_PASTE   1 = auto-wklej (Cmd+V), 0 = zostaw tylko w schowku (domyślnie 1)
#   VOICETYPE_DIR     katalog roboczy (domyślnie /tmp/voice-type)
#
# Wymaga: ffmpeg, whisper-cli (brew install ffmpeg whisper-cpp), uprawnienia Mikrofon + Dostępność.

set -uo pipefail

# Uruchamiany z GUI (Keyboard Maestro / Raycast) ma okrojony PATH — dołóż Homebrew.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

WORKDIR="${VOICETYPE_DIR:-/tmp/voice-type}"
MODEL="${VOICETYPE_MODEL:-$HOME/.local/share/whisper-cpp/ggml-large-v3-turbo.bin}"
LANG_CODE="${VOICETYPE_LANG:-pl}"
MIC="${VOICETYPE_MIC:-:default}"
PROMPT="${VOICETYPE_PROMPT:-}"
PASTE="${VOICETYPE_PASTE:-1}"

mkdir -p "$WORKDIR"
PIDFILE="$WORKDIR/ffmpeg.pid"
WAV="$WORKDIR/rec.wav"
OUT="$WORKDIR/out"   # whisper-cli -of -> $OUT.txt

notify() { # $1 = treść, $2 = (opcjonalnie) nazwa dźwięku
  if [ -n "${2:-}" ]; then
    osascript -e "display notification \"$1\" with title \"VoiceType\" sound name \"$2\"" >/dev/null 2>&1 || true
  else
    osascript -e "display notification \"$1\" with title \"VoiceType\"" >/dev/null 2>&1 || true
  fi
}

# ── Gałąź STOP: trwa nagrywanie -> zakończ i transkrybuj ──────────────────────
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  PID=$(cat "$PIDFILE")
  kill -INT "$PID" 2>/dev/null || true        # SIGINT -> ffmpeg finalizuje WAV
  for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$PID" 2>/dev/null || true
  rm -f "$PIDFILE"

  if [ ! -s "$WAV" ]; then notify "Brak nagrania 🤷"; exit 0; fi
  notify "⏳ Transkrybuję…"

  if [ -n "$PROMPT" ]; then
    whisper-cli -m "$MODEL" -f "$WAV" -l "$LANG_CODE" -nt -np --prompt "$PROMPT" -otxt -of "$OUT" >/dev/null 2>&1
  else
    whisper-cli -m "$MODEL" -f "$WAV" -l "$LANG_CODE" -nt -np -otxt -of "$OUT" >/dev/null 2>&1
  fi

  TEXT=$(sed -e 's/\[BLANK_AUDIO\]//g' -e 's/\[.*\]//g' "$OUT.txt" 2>/dev/null \
         | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
         | sed '/^$/d' | paste -sd ' ' - | tr -s ' ')

  if [ -z "$TEXT" ]; then notify "Nic nie rozpoznano 🤷"; exit 0; fi

  printf '%s' "$TEXT" | pbcopy
  if [ "$PASTE" = "1" ]; then
    osascript -e 'tell application "System Events" to keystroke "v" using command down' >/dev/null 2>&1 || true
  fi
  notify "✅ ${TEXT:0:90}"
  printf '%s' "$TEXT"   # czysty transkrypt na stdout (dla Raycasta / pipe'ów)
  exit 0
fi

# ── Gałąź START: rozpocznij nagrywanie ───────────────────────────────────────
rm -f "$WAV" "$OUT.txt" "$PIDFILE"
nohup ffmpeg -nostdin -hide_banner -loglevel error \
  -f avfoundation -i "$MIC" -ar 16000 -ac 1 -y "$WAV" >/dev/null 2>&1 &
echo $! > "$PIDFILE"
notify "🎙️ Nagrywam… (hotkey ponownie = stop)" "Tink"
exit 0
