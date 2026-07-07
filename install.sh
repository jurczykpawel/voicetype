#!/usr/bin/env bash
#
# VoiceType installer — free, local dictation for macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/jurczykpawel/voicetype/main/install.sh | bash
#
# Interactive: asks which transcription backend to set up. Non-interactive (no TTY) or when
# VOICETYPE_BACKEND is set, it runs unattended. Idempotent: re-running skips what's in place.
#
# Backends:
#   whisper   — local whisper.cpp, offline (downloads ~1.5 GB model)   [default]
#   parakeet  — local Parakeet v3 via parakeet-mlx, offline, multilingual
#   cloud     — cloud APIs (Groq/OpenAI/Deepgram/ElevenLabs); no model download
#   all       — Whisper + Parakeet
#
# Env overrides:
#   VOICETYPE_BACKEND=whisper|parakeet|cloud|all   pick backend, skip the prompt
#   VOICETYPE_MODEL_NAME=ggml-large-v3-turbo.bin   whisper.cpp model file
#   VOICETYPE_BRANCH=main                          git branch for remote fetch
#   VOICETYPE_NO_KM=1                              skip Keyboard Maestro macro import

set -euo pipefail

REPO="jurczykpawel/voicetype"
BRANCH="${VOICETYPE_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"

INSTALL_DIR="$HOME/.voicetype"
ENGINE="$INSTALL_DIR/voice-type.sh"
CONFIG="$INSTALL_DIR/config"
BIN_DIR="$HOME/.local/bin"
MODEL_NAME="${VOICETYPE_MODEL_NAME:-ggml-large-v3-turbo.bin}"
MODEL_DIR="$HOME/.local/share/whisper-cpp"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"

info() { printf "\033[36m▸\033[0m %s\n" "$1"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "\033[33m!\033[0m %s\n" "$1"; }
die()  { printf "\033[31m✗\033[0m %s\n" "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "VoiceType supports macOS only."

# Where this script lives (local clone) — fall back to remote fetch when piped.
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

fetch() { # $1 = repo-relative path, $2 = dest
  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/$1" ]; then
    cp "$SELF_DIR/$1" "$2"
  else
    curl -fsSL "$RAW/$1" -o "$2" || die "Failed to download $1"
  fi
}

# ── Choose backend ────────────────────────────────────────────────────────────
choose_backend() {
  if [ -n "${VOICETYPE_BACKEND:-}" ]; then echo "$VOICETYPE_BACKEND"; return; fi
  # Back-compat with the old opt-in flag.
  if [ "${VOICETYPE_WITH_PARAKEET:-0}" = "1" ]; then echo "all"; return; fi
  if [ ! -e /dev/tty ]; then echo "whisper"; return; fi   # non-interactive default
  {
    printf '\nWhich transcription backend?\n'
    printf '  1) Whisper      — local, offline (~1.5 GB model)   [default]\n'
    printf '  2) Parakeet v3  — local, offline, multilingual\n'
    printf '  3) Cloud only   — no model download (Groq/OpenAI/Deepgram/ElevenLabs)\n'
    printf '  4) All local    — Whisper + Parakeet\n'
    printf 'Selection [1]: '
  } >/dev/tty
  local sel=""; read -r sel </dev/tty || true
  case "$sel" in
    2) echo parakeet ;; 3) echo cloud ;; 4) echo all ;; *) echo whisper ;;
  esac
}

CHOICE="$(choose_backend)"
case "$CHOICE" in local) CHOICE=whisper ;; esac
WANT_WHISPER=0; WANT_PARAKEET=0
case "$CHOICE" in
  whisper)  WANT_WHISPER=1 ;;
  parakeet) WANT_PARAKEET=1 ;;
  cloud)    ;;                         # nothing heavy to install
  all)      WANT_WHISPER=1; WANT_PARAKEET=1 ;;
  *)        die "Unknown backend '$CHOICE' (use whisper|parakeet|cloud|all)" ;;
esac
info "Backend: $CHOICE"

# ── Homebrew ────────────────────────────────────────────────────────────────
command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it from https://brew.sh and re-run."
eval "$(brew shellenv 2>/dev/null || true)"

# ── Dependencies ──────────────────────────────────────────────────────────────
# ffmpeg (recording) and jq (Deepgram/ElevenLabs cloud parsing) are always needed.
DEPS="ffmpeg jq"
[ "$WANT_WHISPER" = 1 ] && DEPS="$DEPS whisper-cpp"
for dep in $DEPS; do
  if brew list --formula "$dep" >/dev/null 2>&1 || command -v "${dep%-cpp}" >/dev/null 2>&1; then
    ok "$dep already installed"
  else
    info "Installing $dep…"; brew install "$dep"
  fi
done
[ "$WANT_WHISPER" = 1 ] && { command -v whisper-cli >/dev/null 2>&1 || die "whisper-cli not on PATH after install."; }

# ── Parakeet (parakeet-mlx via pipx) ──────────────────────────────────────────
if [ "$WANT_PARAKEET" = 1 ]; then
  if command -v parakeet-mlx >/dev/null 2>&1; then
    ok "parakeet-mlx already installed"
  else
    if ! command -v pipx >/dev/null 2>&1; then
      info "Installing pipx…"; brew install pipx; pipx ensurepath >/dev/null 2>&1 || true
    fi
    info "Installing parakeet-mlx…"; pipx install parakeet-mlx || warn "parakeet-mlx install failed (set up manually)"
  fi
fi

# ── Whisper model ───────────────────────────────────────────────────────────
if [ "$WANT_WHISPER" = 1 ]; then
  mkdir -p "$MODEL_DIR"
  if [ -f "$MODEL_PATH" ]; then
    ok "Model present: $MODEL_NAME"
  else
    info "Downloading model $MODEL_NAME (~1.5 GB, one-time)…"
    curl -fL --progress-bar \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME" \
      -o "$MODEL_PATH.part" || die "Model download failed."
    mv "$MODEL_PATH.part" "$MODEL_PATH"
    ok "Model saved to $MODEL_PATH"
  fi
  # VAD model (~0.9 MB) — stops Whisper from hallucinating phantom phrases on silence.
  VAD_PATH="$MODEL_DIR/ggml-silero-v5.1.2.bin"
  if [ -f "$VAD_PATH" ]; then
    ok "VAD model present"
  else
    info "Downloading VAD model (~0.9 MB, one-time)…"
    if curl -fsSL "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" -o "$VAD_PATH.part"; then
      mv "$VAD_PATH.part" "$VAD_PATH"
      ok "VAD model saved"
    else
      rm -f "$VAD_PATH.part"
      info "VAD download skipped (optional) — silence guard + phantom filter still active."
    fi
  fi
fi

# ── Engine + persistent default backend ───────────────────────────────────────
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
fetch "engine/voice-type.sh" "$ENGINE"
chmod +x "$ENGINE"
ln -sf "$ENGINE" "$BIN_DIR/voicetype"

# Persist the default backend (env vars at runtime still override via ${VAR:=...}).
DEFAULT_BACKEND="$CHOICE"; [ "$CHOICE" = "all" ] && DEFAULT_BACKEND="whisper"
{
  echo "# VoiceType defaults (written by installer). Runtime env vars override these."
  echo ": \"\${VOICETYPE_BACKEND:=$DEFAULT_BACKEND}\""
} > "$CONFIG"
ok "Engine installed to $ENGINE (CLI: voicetype, default backend: $DEFAULT_BACKEND)"

# ── Keyboard Maestro macro ─────────────────────────────────────────────────────
if [ "${VOICETYPE_NO_KM:-0}" != "1" ] && [ -d "/Applications/Keyboard Maestro.app" ]; then
  TMP_KM="$(mktemp -t voicetype).kmmacros"
  fetch "keyboard-maestro/voice-type.kmmacros" "$TMP_KM"
  sed -i '' "s|__VOICETYPE_ENGINE__|$ENGINE|g" "$TMP_KM"
  open "$TMP_KM"
  ok "Opened Keyboard Maestro macro for import (Hyper+Space)"
else
  warn "Keyboard Maestro not found (or skipped) — bind a hotkey to: $ENGINE"
fi

# ── Next steps ─────────────────────────────────────────────────────────────────
cat <<EOF

$(ok "VoiceType installed.")

Next steps:
  1. System Settings → Privacy & Security:
       • Microphone   → enable Keyboard Maestro Engine
       • Accessibility → enable Keyboard Maestro Engine   (for auto-paste)
  2. Press Hyper+Space (Caps Lock → ⌃⌥⌘⇧) to start, again to stop + paste.
EOF

if [ "$CHOICE" = "cloud" ]; then
  cat <<EOF
  3. Set your cloud API key, e.g.:
       export GROQ_API_KEY=gsk_...        # free at console.groq.com
     (or VOICETYPE_DEEPGRAM_KEY / VOICETYPE_ELEVENLABS_KEY). See README.
EOF
fi

cat <<EOF

Change backend later: edit $CONFIG, or set VOICETYPE_BACKEND.
CLI test (run twice — start, then stop):  voicetype     # ensure ~/.local/bin is on PATH
EOF
