#!/bin/bash
# voice-type.sh — darmowy odpowiednik SuperWhisper, w 100% lokalnie (whisper.cpp + ffmpeg).
#
# TOGGLE: pierwsze wywołanie = start nagrywania mikrofonu.
#         drugie wywołanie  = stop -> transkrypcja -> tekst do schowka -> auto-wklejenie w miejsce kursora.
#
# Pomyślane jako jeden silnik dla wielu frontendów (Keyboard Maestro hotkey, Raycast, CLI).
#
# Konfiguracja przez zmienne środowiskowe (wszystkie opcjonalne):
#   VOICETYPE_BACKEND   silnik transkrypcji (domyślnie 'local'):
#                         local      — whisper.cpp, offline (domyślny)
#                         parakeet   — Parakeet v3 (parakeet-mlx), offline, multilingual auto
#                         cloud      — OpenAI-compatible API (Groq [darmowy], OpenAI, …)
#                         deepgram   — Deepgram Nova
#                         elevenlabs — ElevenLabs Scribe
#   VOICETYPE_LANG      język (domyślnie pl; 'auto' = autodetekcja)
#   VOICETYPE_MIC       urządzenie ffmpeg avfoundation. Domyślnie ':default' = ŚLEDŹ systemowy
#                       domyślny mikrofon (Ustawienia → Dźwięk → Wejście), z pominięciem niemych
#                       urządzeń wirtualnych (Krisp/Teams/BlackHole/Loopback/RØDE Connect…).
#                       Wymuszenie konkretnego: indeks ':1' albo nazwa ':MacBook Pro Microphone'.
#                       (UWAGA: własne ':default' avfoundation to indeks [0] — często wirtualny,
#                       niemy kanał → cisza → Whisper HALUCYNUJE. Dlatego wybieramy mic sami.)
#   VOICETYPE_MIC_PRIORITY  (personal) ';'-separated substrings, w kolejności priorytetu. Gdy
#                       MIC=':default' i aktualnie podłączone urządzenie pasuje do wpisu, wygrywa —
#                       nawet nad systemowym defaultem macOS. Puste (domyślnie) = brak override'u.
#   VOICETYPE_MIC_AVOID     (personal) ';'-separated substrings urządzeń używanych TYLKO w ostatniej
#                       kolejności (np. słuchawki BT, przez które nie chcesz dyktować przez pomyłkę).
#                       Puste (domyślnie) = żadne urządzenie nie jest unikane.
#   VOICETYPE_PROMPT    initial prompt / słownik nazw własnych (local + cloud OpenAI-compatible)
#   VOICETYPE_PASTE     1 = auto-wklej (Cmd+V), 0 = zostaw tylko w schowku (domyślnie 1)
#   VOICETYPE_DIR       katalog roboczy (domyślnie /tmp/voice-type)
#   VOICETYPE_FORMAT    preset formatowania LLM po transkrypcji (np. 'email'); można też podać
#                       jako argument CLI: --format <nazwa>. Puste (domyślnie) = brak formatowania,
#                       zero zmiany zachowania i zero dodatkowego opóźnienia/kosztu.
#
# format (opcjonalne post-processing przez LLM zgodny z OpenAI /chat/completions):
#   VOICETYPE_FORMAT_URL    endpoint (domyślnie Groq; ustaw na lokalny serwer np. Ollama/LM Studio)
#   VOICETYPE_FORMAT_MODEL  model (domyślnie szybki Groq Llama)
#   VOICETYPE_FORMAT_KEY    klucz; fallback VOICETYPE_CLOUD_KEY, potem GROQ_API_KEY, potem OPENAI_API_KEY
#                           (puste -> brak nagłówka Authorization, dla lokalnych serwerów bez klucza)
#   VOICETYPE_PROMPTS_DIR   katalog presetów (domyślnie ~/.voicetype/prompts); preset = plik <nazwa>.txt,
#                           cała treść pliku to system-prompt wysyłany do LLM
#
# local:       VOICETYPE_MODEL            ścieżka do modelu ggml (domyślnie large-v3-turbo)
# parakeet:    VOICETYPE_PARAKEET_MODEL   repo HF (domyślnie mlx-community/parakeet-tdt-0.6b-v3)
#              VOICETYPE_PARAKEET_BIN     ścieżka do parakeet-mlx (domyślnie 'parakeet-mlx')
# cloud:       VOICETYPE_CLOUD_URL        endpoint (domyślnie Groq /audio/transcriptions)
#              VOICETYPE_CLOUD_MODEL      model (domyślnie whisper-large-v3-turbo)
#              VOICETYPE_CLOUD_KEY        klucz; fallback $GROQ_API_KEY, potem $OPENAI_API_KEY
# deepgram:    VOICETYPE_DEEPGRAM_KEY     klucz; fallback $DEEPGRAM_API_KEY
#              VOICETYPE_DEEPGRAM_MODEL   model (domyślnie nova-3)
# elevenlabs:  VOICETYPE_ELEVENLABS_KEY   klucz; fallback $ELEVENLABS_API_KEY
#              VOICETYPE_ELEVENLABS_MODEL model (domyślnie scribe_v1)
#
# Wymaga: ffmpeg + (whisper-cli | parakeet-mlx | curl). deepgram/elevenlabs: też jq.
# Uprawnienia macOS: Mikrofon + Dostępność.

set -uo pipefail

# Uruchamiany z GUI (Keyboard Maestro / Raycast) ma okrojony PATH — dołóż Homebrew + ~/.local/bin (pipx).
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Opcjonalne trwałe domyślne ustawienia (zapisywane przez installer). Realne zmienne env mają pierwszeństwo
# dzięki idiomowi ${VAR:=...} w pliku configu (ustawia tylko gdy nie podano z zewnątrz).
# shellcheck source=/dev/null
[ -f "$HOME/.voicetype/config" ] && . "$HOME/.voicetype/config"

WORKDIR="${VOICETYPE_DIR:-/tmp/voice-type}"
BACKEND="${VOICETYPE_BACKEND:-local}"
LANG_CODE="${VOICETYPE_LANG:-pl}"
MIC="${VOICETYPE_MIC:-:default}"
MIC_PRIORITY="${VOICETYPE_MIC_PRIORITY:-}"   # personal: ordered ';'-separated substrings, checked before system default
MIC_AVOID="${VOICETYPE_MIC_AVOID:-}"         # personal: ';'-separated substrings, used only as a last resort
PROMPT="${VOICETYPE_PROMPT:-}"
PASTE="${VOICETYPE_PASTE:-1}"
# local (whisper.cpp)
MODEL="${VOICETYPE_MODEL:-$HOME/.local/share/whisper-cpp/ggml-large-v3-turbo.bin}"
# VAD (Voice Activity Detection) — odcina fragmenty bez mowy, żeby Whisper nie halucynował na ciszy.
VAD_MODEL="${VOICETYPE_VAD_MODEL:-$HOME/.local/share/whisper-cpp/ggml-silero-v5.1.2.bin}"
VAD_URL="${VOICETYPE_VAD_URL:-https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin}"
# parakeet (parakeet-mlx)
PARAKEET_BIN="${VOICETYPE_PARAKEET_BIN:-parakeet-mlx}"
PARAKEET_MODEL="${VOICETYPE_PARAKEET_MODEL:-mlx-community/parakeet-tdt-0.6b-v3}"
# cloud / openai-compatible (Groq, OpenAI, …)
CLOUD_URL="${VOICETYPE_CLOUD_URL:-https://api.groq.com/openai/v1/audio/transcriptions}"
CLOUD_MODEL="${VOICETYPE_CLOUD_MODEL:-whisper-large-v3-turbo}"
# format LLM (OpenAI-compatible chat/completions) — niezależny od backendu transkrypcji
FORMAT="${VOICETYPE_FORMAT:-}"
FORMAT_URL="${VOICETYPE_FORMAT_URL:-https://api.groq.com/openai/v1/chat/completions}"
FORMAT_MODEL="${VOICETYPE_FORMAT_MODEL:-llama-3.3-70b-versatile}"
PROMPTS_DIR="${VOICETYPE_PROMPTS_DIR:-$HOME/.voicetype/prompts}"
# deepgram
DEEPGRAM_MODEL="${VOICETYPE_DEEPGRAM_MODEL:-nova-3}"
# elevenlabs
ELEVENLABS_MODEL="${VOICETYPE_ELEVENLABS_MODEL:-scribe_v1}"

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

need_jq() { command -v jq >/dev/null 2>&1 || { notify "Brak jq (brew install jq)"; return 1; }; }

# Wzorzec nazw "martwych" urządzeń wirtualnych/agregatowych — dają ciszę bez routingu w apce.
VIRT_RE='Connect|BlackHole|Loopback|Aggregate|Multi-Output|VB-Cable|VB-Audio|Soundflower|Krisp|iShowU|Background Music'

# Nazwa aktualnego systemowego domyślnego mikrofonu (macOS). Pusty = nie ustalono.
# Preferuje SwitchAudioSource (szybki), fallback system_profiler (bez zależności).
default_input_name() {
  if command -v SwitchAudioSource >/dev/null 2>&1; then
    SwitchAudioSource -c -t input 2>/dev/null && return
  fi
  system_profiler SPAudioDataType 2>/dev/null | awk '
    /^        [^ ].*:$/ { name=$0; sub(/^ +/,"",name); sub(/:$/,"",name) }
    /Default Input Device: Yes/ { print name; exit }
  '
}

# Lista wejść audio avfoundation, jedno urządzenie na linię (bez indeksów).
list_avfoundation_devices() {
  ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
    | sed -n '/audio devices/,$p' | sed -E 's/^.*\] \[[0-9]+\] //'
}

# Czy $1 pasuje do któregoś z ';'-rozdzielonych wpisów VOICETYPE_MIC_AVOID?
is_avoided() {
  [ -n "$MIC_AVOID" ] || return 1
  printf '%s' "$1" | grep -qiF -f <(printf '%s\n' "${MIC_AVOID//;/$'\n'}")
}

# Usuwa ze stdin linie pasujące do VOICETYPE_MIC_AVOID (no-op gdy pusty).
filter_avoided() {
  if [ -n "$MIC_AVOID" ]; then
    grep -viF -f <(printf '%s\n' "${MIC_AVOID//;/$'\n'}")
  else
    cat
  fi
}

# Auto-wybór REALNEGO mikrofonu dla MIC=':default' (uniwersalnie, nie pod jeden sprzęt):
#   0) VOICETYPE_MIC_PRIORITY (personal, opcjonalny) — pierwsze aktualnie podłączone urządzenie
#      z tej listy wygrywa, z pominięciem reszty logiki poniżej;
#   1) systemowy domyślny input — o ile to NIE martwe urządzenie wirtualne ani VOICETYPE_MIC_AVOID
#      (macOS sam przełącza default na wpięty mic USB, więc zwykle wystarcza ten krok);
#   2) inaczej wbudowany mikrofon (zawsze ma sygnał; "odłączony → wbudowany");
#   3) inaczej pierwszy nie-wirtualny, nie-unikany input z listy;
#   4) inaczej (wszystko unikane) pierwszy nie-wirtualny input mimo wszystko — lepiej to niż cisza.
#   Pusto → wołający zostaje przy ':default'.
resolve_auto_mic() {
  local def list mbp real parts entry match
  if [ -n "$MIC_PRIORITY" ]; then
    list=$(list_avfoundation_devices)
    IFS=';' read -ra parts <<< "$MIC_PRIORITY"
    for entry in "${parts[@]}"; do
      [ -n "$entry" ] || continue
      match=$(printf '%s\n' "$list" | grep -iF "$entry" | head -1)
      if [ -n "$match" ]; then printf '%s' "$match"; return; fi
    done
  fi
  def=$(default_input_name)
  if [ -n "$def" ] && ! printf '%s' "$def" | grep -qiE "$VIRT_RE" && ! is_avoided "$def"; then
    printf '%s' "$def"; return
  fi
  list=$(list_avfoundation_devices)
  mbp=$(printf '%s\n' "$list" | grep -iE 'MacBook.*Microphone|Built-in.*Micro' | head -1)
  if [ -n "$mbp" ] && ! is_avoided "$mbp"; then printf '%s' "$mbp"; return; fi
  real=$(printf '%s\n' "$list" | grep -viE "$VIRT_RE" | filter_avoided | grep -iE 'micro|mic|input|usb' | head -1)
  if [ -n "$real" ]; then printf '%s' "$real"; return; fi
  # Ostatnia deska ratunku: wszystko nie-wirtualne wykluczone/unikane — bierz cokolwiek zostało
  # (avfoundation i tak listuje same wejścia audio, filtr nazw tu tylko by szkodził, np. "WH-1000XM4").
  real=$(printf '%s\n' "$list" | grep -viE "$VIRT_RE" | head -1)
  if [ -n "$real" ]; then printf '%s' "$real"; return; fi
  printf '%s' "$def"
}

# Ściąga model VAD raz (mały, ~0,9 MB). Marker .failed = nie próbuj w kółko gdy offline.
ensure_vad_model() {
  [ -f "$VAD_MODEL" ] && return 0
  [ -f "$VAD_MODEL.failed" ] && return 1
  mkdir -p "$(dirname "$VAD_MODEL")"
  if curl -fsSL -o "$VAD_MODEL.part" "$VAD_URL" 2>/dev/null; then
    mv "$VAD_MODEL.part" "$VAD_MODEL"
  else
    rm -f "$VAD_MODEL.part"; touch "$VAD_MODEL.failed"; return 1
  fi
}

# Znane fantomy Whispera (zwrot z ciszy/szumu). Całe wyjście == fantom -> traktuj jak brak mowy.
_phantom_norm() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[.!?…]*$//' | tr '[:upper:]' '[:lower:]'; }
is_phantom() {
  case "$(_phantom_norm "$1")" in
    "dziękuję za uwagę"|"dzięki za uwagę"|"dziękuję za oglądanie"|"dzięki za oglądanie"|\
    "dziękuję za obejrzenie"|"dziękuję"|"dzięki"|"dziękuję za obejrzenie filmu"|\
    "napisy stworzone przez społeczność amara.org"|"napisy: amara.org"|\
    "zapraszam do subskrypcji"|"prosimy o subskrypcję"|"do zobaczenia"|\
    "thank you for watching"|"thanks for watching"|"thank you"|"you"|"bye"|\
    "subtitles by the amara.org community"|"please subscribe") return 0 ;;
  esac
  return 1
}

# Transkrypcja lokalna (whisper.cpp) -> surowy tekst na stdout. VAD gdy model dostępny.
transcribe_local() {
  local args=(-m "$MODEL" -f "$WAV" -l "$LANG_CODE" -nt -np -otxt -of "$OUT")
  # pad 200ms: default 30ms clips short words (single-letter "w"/"z") at segment edges
  ensure_vad_model && args+=(--vad --vad-model "$VAD_MODEL" --vad-speech-pad-ms 200)
  [ -n "$PROMPT" ] && args+=(--prompt "$PROMPT")
  whisper-cli "${args[@]}" >/dev/null 2>&1
  cat "$OUT.txt" 2>/dev/null
}

# Transkrypcja lokalna (Parakeet v3 via parakeet-mlx) -> surowy tekst na stdout.
# Multilingual z auto-detekcją języka (25 jęz. EU, w tym PL i EN). Brak flagi prompt/język.
transcribe_parakeet() {
  if ! command -v "$PARAKEET_BIN" >/dev/null 2>&1; then
    notify "Parakeet: brak '$PARAKEET_BIN' (pip install parakeet-mlx)"; return 1
  fi
  rm -f "$WORKDIR/rec.txt"
  "$PARAKEET_BIN" "$WAV" --model "$PARAKEET_MODEL" --output-format txt --output-dir "$WORKDIR" >/dev/null 2>&1 \
    || { notify "Parakeet: transkrypcja nieudana ❌"; return 1; }
  cat "$WORKDIR/rec.txt" 2>/dev/null
}

# Transkrypcja w chmurze (endpoint zgodny z OpenAI /audio/transcriptions: Groq, OpenAI, …).
transcribe_cloud() {
  local key="${VOICETYPE_CLOUD_KEY:-${GROQ_API_KEY:-${OPENAI_API_KEY:-}}}"
  if [ -z "$key" ]; then notify "Cloud: brak klucza API (VOICETYPE_CLOUD_KEY)"; return 1; fi
  local args=(-fsS "$CLOUD_URL" -H "Authorization: Bearer $key"
              -F "file=@$WAV" -F "model=$CLOUD_MODEL" -F "response_format=text")
  if [ -n "$LANG_CODE" ] && [ "$LANG_CODE" != "auto" ]; then args+=(-F "language=$LANG_CODE"); fi
  if [ -n "$PROMPT" ]; then args+=(-F "prompt=$PROMPT"); fi
  curl "${args[@]}" || { notify "Cloud: błąd sieci/API ❌"; return 1; }
}

# Transkrypcja Deepgram (Nova). language=multi gdy 'auto'.
transcribe_deepgram() {
  local key="${VOICETYPE_DEEPGRAM_KEY:-${DEEPGRAM_API_KEY:-}}"
  if [ -z "$key" ]; then notify "Deepgram: brak klucza (VOICETYPE_DEEPGRAM_KEY)"; return 1; fi
  need_jq || return 1
  local lang="$LANG_CODE"; [ "$lang" = "auto" ] && lang="multi"
  local url="https://api.deepgram.com/v1/listen?model=$DEEPGRAM_MODEL&smart_format=true"
  [ -n "$lang" ] && url="$url&language=$lang"
  curl -fsS -X POST "$url" -H "Authorization: Token $key" -H "Content-Type: audio/wav" --data-binary @"$WAV" \
    2>/dev/null | jq -r '.results.channels[0].alternatives[0].transcript // empty' \
    || { notify "Deepgram: błąd sieci/API ❌"; return 1; }
}

# Transkrypcja ElevenLabs Scribe.
transcribe_elevenlabs() {
  local key="${VOICETYPE_ELEVENLABS_KEY:-${ELEVENLABS_API_KEY:-}}"
  if [ -z "$key" ]; then notify "ElevenLabs: brak klucza (VOICETYPE_ELEVENLABS_KEY)"; return 1; fi
  need_jq || return 1
  local args=(-fsS -X POST "https://api.elevenlabs.io/v1/speech-to-text"
              -H "xi-api-key: $key" -F "file=@$WAV" -F "model_id=$ELEVENLABS_MODEL")
  if [ -n "$LANG_CODE" ] && [ "$LANG_CODE" != "auto" ]; then args+=(-F "language_code=$LANG_CODE"); fi
  curl "${args[@]}" 2>/dev/null | jq -r '.text // empty' \
    || { notify "ElevenLabs: błąd sieci/API ❌"; return 1; }
}

# Formatowanie tekstu przez LLM zgodny z OpenAI /chat/completions (Groq, OpenAI, lokalny Ollama/LM Studio…).
# $1 = surowy tekst, $2 = nazwa presetu (plik $PROMPTS_DIR/$2.txt = system-prompt).
# stdout = sformatowany tekst. Zwraca: 0 = sukces, 1 = błąd przejściowy (caller ma fallback na surowy
# tekst), 2 = nieznany preset (błąd configu, caller ma przerwać zamiast wklejać cokolwiek).
format_llm() {
  local text="$1" preset="$2" prompt_file key sys_prompt body args resp out
  prompt_file="$PROMPTS_DIR/$preset.txt"
  if [ ! -f "$prompt_file" ]; then
    notify "❌ nieznany format: $preset"
    return 2
  fi
  need_jq || return 1
  key="${VOICETYPE_FORMAT_KEY:-${VOICETYPE_CLOUD_KEY:-${GROQ_API_KEY:-${OPENAI_API_KEY:-}}}}"
  sys_prompt=$(cat "$prompt_file")
  body=$(jq -n --arg model "$FORMAT_MODEL" --arg sys "$sys_prompt" --arg user "$text" \
    '{model: $model, messages: [{role: "system", content: $sys}, {role: "user", content: $user}], temperature: 0.2}')
  args=(-fsS --max-time 15 "$FORMAT_URL" -H "Content-Type: application/json" -d "$body")
  [ -n "$key" ] && args+=(-H "Authorization: Bearer $key")
  resp=$(curl "${args[@]}" 2>/dev/null) || return 1
  out=$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  [ -n "$out" ] || return 1
  # Zdejmij ewentualny markdown code-fence, gdyby model mimo instrukcji w prompcie go dodał.
  out=$(printf '%s' "$out" | sed -e '1{/^```/d;}' -e '${/^```$/d;}')
  printf '%s' "$out"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --format) FORMAT="$2"; shift 2 ;;
      --format=*) FORMAT="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  # ── Gałąź STOP: trwa nagrywanie -> zakończ i transkrybuj ──────────────────────
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    PID=$(cat "$PIDFILE")
    kill -INT "$PID" 2>/dev/null || true        # SIGINT -> ffmpeg finalizuje WAV
    for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$PID" 2>/dev/null || true
    rm -f "$PIDFILE"

    if [ ! -s "$WAV" ]; then notify "Brak nagrania 🤷"; exit 0; fi

    # Straż ciszy: martwe/wirtualne urządzenie (albo brak zgody na mikrofon) daje ~ -91 dB.
    # Bez tego Whisper na ciszy HALUCYNUJE (klasyczne "Dziękuję za uwagę."). Próg -70 dB.
    DEV_USED=$(cat "$WORKDIR/mic" 2>/dev/null || echo "${MIC#:}")
    MAXVOL=$(ffmpeg -hide_banner -i "$WAV" -af volumedetect -f null - 2>&1 \
             | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB/\1/p')
    if [ -n "$MAXVOL" ] && awk "BEGIN{exit !($MAXVOL < -70)}"; then
      notify "🔇 Cisza z '$DEV_USED' (${MAXVOL} dB) — sprawdź mikrofon / zgodę na Mikrofon"
      exit 0
    fi
    notify "⏳ Transkrybuję… (${DEV_USED})"

    case "$BACKEND" in
      parakeet)          RAW=$(transcribe_parakeet)   || exit 1 ;;
      cloud|openai|groq) RAW=$(transcribe_cloud)      || exit 1 ;;
      deepgram)          RAW=$(transcribe_deepgram)   || exit 1 ;;
      elevenlabs)        RAW=$(transcribe_elevenlabs) || exit 1 ;;
      *)                 RAW=$(transcribe_local) ;;   # whisper / local (domyślnie)
    esac

    TEXT=$(printf '%s' "$RAW" \
           | sed -e 's/\[BLANK_AUDIO\]//g' -e 's/\[.*\]//g' \
           | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
           | sed '/^$/d' | paste -sd ' ' - | tr -s ' ')

    # Całe wyjście to fantom Whispera z ciszy (VAD go zwykle ubija, to siatka bezpieczeństwa
    # także dla backendów chmurowych bez VAD) -> nie wklejaj.
    if [ -z "$TEXT" ] || is_phantom "$TEXT"; then notify "Nic nie rozpoznano 🤷"; exit 0; fi

    STOP_FORMAT=$(cat "$WORKDIR/format" 2>/dev/null || true)
    if [ -n "$STOP_FORMAT" ]; then
      FORMATTED=$(format_llm "$TEXT" "$STOP_FORMAT"); rc=$?
      if [ $rc -eq 0 ]; then
        TEXT="$FORMATTED"
      elif [ $rc -eq 2 ]; then
        exit 0   # nieznany preset — format_llm już zanotyfikował błąd, nic nie wklejaj
      else
        notify "⚠️ formatowanie nieudane — wklejono surowy tekst"
      fi
    fi

    printf '%s' "$TEXT" | pbcopy
    if [ "$PASTE" = "1" ]; then
      osascript -e 'tell application "System Events" to keystroke "v" using command down' >/dev/null 2>&1 || true
    fi
    notify "✅ ${TEXT:0:90}"
    printf '%s' "$TEXT"   # czysty transkrypt na stdout (dla Raycasta / pipe'ów)
    exit 0
  fi

  # ── Gałąź START: rozpocznij nagrywanie ───────────────────────────────────────
  # ':default' avfoundation = indeks [0] (często wirtualny, niemy), NIE systemowy default.
  # Auto-wybieramy realny mikrofon (wpięty USB → USB; odłączony → wbudowany) i podajemy po nazwie.
  if [ "$MIC" = ":default" ]; then
    DEV_NAME=$(resolve_auto_mic)
    if [ -n "$DEV_NAME" ]; then MIC=":$DEV_NAME"; fi
  fi
  printf '%s' "${MIC#:}" > "$WORKDIR/mic"   # zapamiętaj urządzenie dla gałęzi STOP
  printf '%s' "$FORMAT" > "$WORKDIR/format"   # zapamiętaj wybrany preset dla gałęzi STOP
  rm -f "$WAV" "$OUT.txt" "$PIDFILE"
  nohup ffmpeg -nostdin -hide_banner -loglevel error \
    -f avfoundation -i "$MIC" -ar 16000 -ac 1 -y "$WAV" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  notify "🎙️ Nagrywam z '${MIC#:}'… (hotkey = stop)" "Tink"
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
