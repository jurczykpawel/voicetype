#!/usr/bin/env bash
#
# VoiceType installer — free, local dictation for macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/jurczykpawel/voicetype/main/install.sh | bash
#
# Installs the engine + dependencies + whisper model, and imports the Keyboard Maestro macro.
# Idempotent: re-running skips anything already in place.
#
# Env overrides:
#   VOICETYPE_MODEL_NAME   whisper.cpp model file (default ggml-large-v3-turbo.bin)
#   VOICETYPE_BRANCH       git branch for remote fetch (default main)
#   VOICETYPE_NO_KM=1      skip Keyboard Maestro macro import

set -euo pipefail

REPO="jurczykpawel/voicetype"
BRANCH="${VOICETYPE_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"

INSTALL_DIR="$HOME/.voicetype"
ENGINE="$INSTALL_DIR/voice-type.sh"
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

# Fetch a repo file into $2 (local copy if available, else download).
fetch() { # $1 = repo-relative path, $2 = dest
  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/$1" ]; then
    cp "$SELF_DIR/$1" "$2"
  else
    curl -fsSL "$RAW/$1" -o "$2" || die "Failed to download $1"
  fi
}

# ── 1. Homebrew ───────────────────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew not found. Install it from https://brew.sh and re-run."
fi
eval "$(brew shellenv 2>/dev/null || true)"

# ── 2. Dependencies ─────────────────────────────────────────────────────────
for dep in ffmpeg whisper-cpp; do
  if brew list --formula "$dep" >/dev/null 2>&1 || command -v "${dep%-cpp}" >/dev/null 2>&1; then
    ok "$dep already installed"
  else
    info "Installing $dep…"; brew install "$dep"
  fi
done
command -v whisper-cli >/dev/null 2>&1 || die "whisper-cli not on PATH after install."

# ── 3. Whisper model ──────────────────────────────────────────────────────────
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

# ── 4. Engine ───────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
fetch "engine/voice-type.sh" "$ENGINE"
chmod +x "$ENGINE"
ln -sf "$ENGINE" "$BIN_DIR/voicetype"
ok "Engine installed to $ENGINE (CLI: voicetype)"

# ── 5. Keyboard Maestro macro ─────────────────────────────────────────────────
if [ "${VOICETYPE_NO_KM:-0}" != "1" ] && [ -d "/Applications/Keyboard Maestro.app" ]; then
  TMP_KM="$(mktemp -t voicetype).kmmacros"
  fetch "keyboard-maestro/voice-type.kmmacros" "$TMP_KM"
  # Substitute the engine path into the macro template.
  sed -i '' "s|__VOICETYPE_ENGINE__|$ENGINE|g" "$TMP_KM"
  open "$TMP_KM"
  ok "Opened Keyboard Maestro macro for import (Hyper+Space)"
else
  warn "Keyboard Maestro not found (or skipped) — bind a hotkey to: $ENGINE"
fi

# ── 6. Next steps ─────────────────────────────────────────────────────────────
cat <<EOF

$(ok "VoiceType installed.")

Next steps:
  1. System Settings → Privacy & Security:
       • Microphone   → enable Keyboard Maestro Engine
       • Accessibility → enable Keyboard Maestro Engine   (for auto-paste)
  2. Press Hyper+Space (Caps Lock → ⌃⌥⌘⇧) to start, again to stop + paste.

Optional CLI test (run twice — start, then stop):
       voicetype        # ensure ~/.local/bin is on your PATH

Config via env vars (see README): VOICETYPE_LANG, VOICETYPE_MIC, VOICETYPE_MODEL, VOICETYPE_PASTE
EOF
