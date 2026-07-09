# LLM Post-Formatting + Personal Mic Priority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add (1) an opt-in `--format <preset>` post-processing step that runs a transcript through any OpenAI-compatible chat-completions endpoint (cloud or local) before pasting, and (2) a personal (Pawel-only) mic priority/avoid mechanism so the RØDE PodMic USB is always preferred and the WH-1000XM4 headset mic is a last resort.

**Architecture:** Both features are added to the single shared bash engine (`engine/voice-type.sh`), following its existing "env var + optional CLI override" idiom and its OpenAI-compatible-endpoint precedent (`transcribe_cloud`). State that must survive across the START→STOP toggle (the chosen mic, the chosen format) is persisted to files in `$WORKDIR`, exactly like the existing `$WORKDIR/mic` file. The engine gets a `main()` wrapper + a `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` run-guard so its functions become sourceable and unit-testable without triggering a real recording.

**Tech Stack:** bash, ffmpeg (avfoundation), curl, jq, whisper-cli. Windows port in PowerShell (`windows/voice-type.ps1`). Raycast extension in TypeScript.

## Global Constraints

- Full spec: `docs/superpowers/specs/2026-07-08-llm-format-and-mic-priority-design.md`.
- The 4 macOS copies of the engine must stay byte-identical after every change (`engine/voice-type.sh`, `raycast/assets/voice-type.sh`, `/Users/pavvel/workspace/scripts/media/voice-type.sh`, `/Users/pavvel/.config/raycast/extensions/voicetype/assets/voice-type.sh`) — verify with `md5 -q` after every sync.
- CI is `shellcheck install.sh engine/voice-type.sh` (default level — no `A && B || C`, use if/else) + PowerShell `ParseFile` on `windows/*.ps1` + Raycast `tsc`/`eslint`/`prettier`. Every commit must keep it green.
- Mic-priority feature (`VOICETYPE_MIC_PRIORITY` / `VOICETYPE_MIC_AVOID`) is macOS-only and generic (no hardware names in the shared script). Pawel's personal values live only in his local `~/.voicetype/config`, never committed.
- LLM-format feature scope is the OSS `voicetype` engine (macOS + Windows) only — explicitly NOT the "Dyktowanie AI bez abonamentu" lead magnet.
- Fallback rule: LLM formatting failure (network/timeout/bad key) → paste the raw transcript + warn. Unknown `--format` preset name → abort, paste nothing (config error, not transient failure).

---

### Task 1: Testability refactor + personal mic priority/avoid mechanism

**Files:**
- Modify: `engine/voice-type.sh` (all line numbers below refer to the file's state at the start of this task)
- Create: `engine/voice-type.test.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `list_avfoundation_devices()` (stdout: one device name per line), `is_avoided(name)` (return 0 if `name` matches `$MIC_AVOID`), `resolve_auto_mic()` (unchanged signature/stdout contract, extended behavior), `main()` (wraps existing STOP+START logic, called with `"$@"`).
- Consumes: existing globals `VIRT_RE`, `WORKDIR`, `MIC`, `PIDFILE`, `WAV`, `OUT`, `notify()`, `default_input_name()`.

- [ ] **Step 1: Add `MIC_PRIORITY`/`MIC_AVOID` globals**

In `engine/voice-type.sh`, right after the line `MIC="${VOICETYPE_MIC:-:default}"` (currently line 54), add:

```bash
MIC_PRIORITY="${VOICETYPE_MIC_PRIORITY:-}"   # personal: ordered ';'-separated substrings, checked before system default
MIC_AVOID="${VOICETYPE_MIC_AVOID:-}"         # personal: ';'-separated substrings, used only as a last resort
```

Also extend the header comment block (near the existing `VOICETYPE_MIC` doc lines 17-22) with:

```bash
#   VOICETYPE_MIC_PRIORITY  (personal) ';'-separated substrings, in priority order. If MIC=':default'
#                       and a currently-connected device matches an entry, it wins — even over the
#                       macOS system default. Empty (default) = no override.
#   VOICETYPE_MIC_AVOID     (personal) ';'-separated substrings for devices to use only as a last
#                       resort (e.g. a Bluetooth headset you don't want to dictate through by
#                       accident). Empty (default) = no device is avoided.
```

- [ ] **Step 2: Extract `list_avfoundation_devices()` and add `is_avoided()`**

Replace the `resolve_auto_mic()` function (currently lines 103-121) with:

```bash
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
  real=$(printf '%s\n' "$list" | grep -viE "$VIRT_RE" | grep -iE 'micro|mic|input|usb' | head -1)
  if [ -n "$real" ]; then printf '%s' "$real"; return; fi
  printf '%s' "$def"
}
```

- [ ] **Step 3: Wrap the STOP+START logic in `main()` with a run-guard**

The file currently ends (from the `# ── Gałąź STOP` comment, currently line 207, to the final `exit 0`, currently line 267) with top-level script logic. Indent that entire block by one level and wrap it:

```bash
main() {
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
```

- [ ] **Step 4: Run shellcheck to verify the refactor is clean**

Run: `shellcheck engine/voice-type.sh`
Expected: no output (clean pass). If SC2086/SC2015 etc. appear, fix inline before continuing (do not suppress with `# shellcheck disable` unless truly a false positive).

- [ ] **Step 5: Write `engine/voice-type.test.sh`**

Create `engine/voice-type.test.sh`:

```bash
#!/bin/bash
# Testy jednostkowe dla resolve_auto_mic()/is_avoided()/filter_avoided() —
# źródłuje silnik (dzięki run-guard nie odpala prawdziwego nagrywania) i
# podstawia fake'i pod default_input_name/list_avfoundation_devices.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FAIL=0
assert_eq() { # $1=opis $2=oczekiwane $3=otrzymane
  if [ "$2" = "$3" ]; then
    echo "ok - $1"
  else
    echo "FAIL - $1: expected '$2', got '$3'"
    FAIL=1
  fi
}

export VOICETYPE_DIR="$(mktemp -d)"
export VOICETYPE_MIC_PRIORITY=""
export VOICETYPE_MIC_AVOID=""
# shellcheck source=/dev/null
source ./voice-type.sh

FAKE_LIST=$'RØDE Connect System\nWH-1000XM4\nMacBook Pro Microphone\nMicrosoft Teams Audio\nRØDE Connect Stream\nRØDE PodMic USB\nRØDE Connect Virtual'
list_avfoundation_devices() { printf '%s\n' "$FAKE_LIST"; }

# Test 1: priorytet wygrywa nawet gdy systemowy default to unikane słuchawki.
default_input_name() { printf 'WH-1000XM4'; }
MIC_PRIORITY="PodMic"; MIC_AVOID="WH-1000XM4"
assert_eq "priority beats avoided system default" "RØDE PodMic USB" "$(resolve_auto_mic)"

# Test 2: bez priorytetu, systemowy default unikany -> pomijamy go, trafiamy w built-in.
MIC_PRIORITY=""; MIC_AVOID="WH-1000XM4"
assert_eq "avoid list skips system default, falls to built-in" "MacBook Pro Microphone" "$(resolve_auto_mic)"

# Test 3: systemowy default prawidłowy i nie-unikany -> używamy go wprost.
default_input_name() { printf 'MacBook Pro Microphone'; }
assert_eq "valid non-avoided system default wins" "MacBook Pro Microphone" "$(resolve_auto_mic)"

# Test 4: last-resort — jedyne dostępne realne urządzenie jest na liście unikanych.
FAKE_LIST_ONLY_AVOIDED=$'RØDE Connect System\nWH-1000XM4'
list_avfoundation_devices() { printf '%s\n' "$FAKE_LIST_ONLY_AVOIDED"; }
default_input_name() { printf ''; }
MIC_AVOID="WH-1000XM4"
assert_eq "last resort falls back to avoided device when nothing else exists" "WH-1000XM4" "$(resolve_auto_mic)"

# Test 5: is_avoided / filter_avoided semantyka wprost.
MIC_AVOID="WH-1000XM4;Teams"
if is_avoided "WH-1000XM4"; then echo "ok - is_avoided matches WH-1000XM4"; else echo "FAIL - is_avoided should match WH-1000XM4"; FAIL=1; fi
if is_avoided "RØDE PodMic USB"; then echo "FAIL - is_avoided should not match RØDE PodMic USB"; FAIL=1; else echo "ok - is_avoided does not match RØDE PodMic USB"; fi
FILTERED=$(printf 'RØDE PodMic USB\nMicrosoft Teams Audio\nWH-1000XM4\n' | filter_avoided)
assert_eq "filter_avoided drops both avoided entries" "RØDE PodMic USB" "$FILTERED"

rm -rf "$VOICETYPE_DIR"
exit $FAIL
```

- [ ] **Step 6: Run the test script to verify it fails without the mic-priority code**

This step is retroactive verification of test validity: temporarily stash Steps 1-2 (`git stash`), run the test, confirm failures, then restore.

Run: `git stash && bash engine/voice-type.test.sh; echo "exit=$?"; git stash pop`
Expected: multiple `FAIL -` lines (priority/avoid vars don't exist yet) and `exit=1`, then the stash is restored (Steps 1-2 back in place).

- [ ] **Step 7: Run the test script against the real implementation**

Run: `bash engine/voice-type.test.sh; echo "exit=$?"`
Expected: every line starts with `ok -`, final `exit=0`.

- [ ] **Step 8: Add the test script to CI**

In `.github/workflows/ci.yml`, in the `shellcheck` job, after the existing `ShellCheck scripts` step, add:

```yaml
      - name: ShellCheck the test script itself
        run: shellcheck engine/voice-type.test.sh
      - name: Unit tests (resolve_auto_mic)
        run: bash engine/voice-type.test.sh
```

- [ ] **Step 9: Sync the canonical engine to the other 3 macOS copies**

Run:
```bash
SRC=engine/voice-type.sh
cp "$SRC" raycast/assets/voice-type.sh
cp "$SRC" /Users/pavvel/workspace/scripts/media/voice-type.sh
cp "$SRC" "/Users/pavvel/.config/raycast/extensions/voicetype/assets/voice-type.sh"
for f in "$SRC" raycast/assets/voice-type.sh /Users/pavvel/workspace/scripts/media/voice-type.sh "/Users/pavvel/.config/raycast/extensions/voicetype/assets/voice-type.sh"; do md5 -q "$f"; done
```
Expected: all four md5 hashes identical.

- [ ] **Step 10: Commit**

```bash
git add engine/voice-type.sh engine/voice-type.test.sh raycast/assets/voice-type.sh .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
feat(mic): add personal mic priority/avoid override + make engine sourceable for tests

Adds VOICETYPE_MIC_PRIORITY/VOICETYPE_MIC_AVOID (generic, no hardware names
in the shared script) so resolve_auto_mic() can be overridden per-machine.
Wraps STOP/START logic in main() behind a run-guard so the engine can be
sourced and unit-tested without triggering a real recording.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

(Note: `scripts/media/voice-type.sh` and the installed Raycast extension copy live outside this git repo — they were already synced via `cp` in Step 9 and need no separate commit.)

---

### Task 2: `--format` CLI flag + `format_llm()` + default "email" preset

**Files:**
- Modify: `engine/voice-type.sh`
- Create: `prompts/email.txt`
- Create: `engine/voice-type-format.test.sh`

**Interfaces:**
- Consumes: `main()`, `WORKDIR`, `notify()`, `need_jq()` from Task 1.
- Produces: `format_llm(text, preset)` (stdout: formatted text; return 0 = success, 1 = transient failure → caller falls back to raw, 2 = unknown preset → caller aborts).

- [ ] **Step 1: Add format-related globals + header docs**

Right after the cloud-backend globals (currently `CLOUD_MODEL="${VOICETYPE_CLOUD_MODEL:-whisper-large-v3-turbo}"`), add:

```bash
# format LLM (OpenAI-compatible chat/completions) — niezależny od backendu transkrypcji
FORMAT="${VOICETYPE_FORMAT:-}"
FORMAT_URL="${VOICETYPE_FORMAT_URL:-https://api.groq.com/openai/v1/chat/completions}"
FORMAT_MODEL="${VOICETYPE_FORMAT_MODEL:-llama-3.3-70b-versatile}"
PROMPTS_DIR="${VOICETYPE_PROMPTS_DIR:-$HOME/.voicetype/prompts}"
```

Extend the header doc block (after the `VOICETYPE_DIR` line, currently line 25) with:

```bash
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
```

- [ ] **Step 2: Add `format_llm()`**

Add the function right after `transcribe_elevenlabs()` (before the `# ── Gałąź STOP` comment / `main()`):

```bash
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
  out=$(printf '%s' "$out" | sed -e '1{/^```/d}' -e '${/^```$/d}')
  printf '%s' "$out"
}
```

- [ ] **Step 3: Parse `--format` in `main()` and persist it at START**

At the very top of `main()` (before the `# ── Gałąź STOP` comment), add:

```bash
  local arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --format) FORMAT="$2"; shift 2 ;;
      --format=*) FORMAT="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
```

In the START branch, right after the line `printf '%s' "${MIC#:}" > "$WORKDIR/mic"`, add:

```bash
  printf '%s' "$FORMAT" > "$WORKDIR/format"   # zapamiętaj wybrany preset dla gałęzi STOP
```

- [ ] **Step 4: Apply formatting in the STOP branch**

In the STOP branch, right after the line `if [ -z "$TEXT" ] || is_phantom "$TEXT"; then notify "Nic nie rozpoznano 🤷"; exit 0; fi`, add:

```bash
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
```

- [ ] **Step 5: Run shellcheck**

Run: `shellcheck engine/voice-type.sh`
Expected: clean pass.

- [ ] **Step 6: Create the default "email" preset**

Create `prompts/email.txt`:

```
Jesteś asystentem formatującym dyktowany tekst na gotowy do wysłania e-mail po polsku.

Zasady:
- Popraw interpunkcję, wielkie litery na początku zdań, oczywiste potknięcia mowy (powtórzone słowa, "yyy", "no").
- Podziel tekst na czytelne akapity.
- Jeśli treść na to wskazuje, dodaj krótkie powitanie na początku i krótkie zakończenie/pozdrowienie na końcu — tylko jeśli naturalnie pasuje, nie zmyślaj imion ani nazwisk, których nie było w tekście.
- Nie dodawaj niczego, czego użytkownik nie powiedział — nie wymyślaj faktów, dat, nazw.
- Nie tłumacz na inny język.
- Zwróć WYŁĄCZNIE finalną treść maila. Bez komentarza, bez "Oto Twój e-mail:", bez cudzysłowów, bez markdown/code-fence.
```

- [ ] **Step 7: Write a mock-server test for `format_llm()`**

Create `engine/voice-type-format.test.sh`:

```bash
#!/bin/bash
# Test format_llm() end-to-end przeciw lokalnemu fake OpenAI-compatible serwerowi (python3 http.server),
# bez potrzeby prawdziwego klucza API.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: expected '$2', got '$3'"; FAIL=1; fi
}

PORT=8934
WORKDIR_TEST=$(mktemp -d)
PROMPTS_TEST=$(mktemp -d)
printf 'Jesteś testowym formatterem. Zwróć dokładnie: FORMATTED-OK\n' > "$PROMPTS_TEST/email.txt"

cat > "$WORKDIR_TEST/fake_server.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length) or b'{}')
        user_msg = next((m['content'] for m in body.get('messages', []) if m['role'] == 'user'), '')
        if user_msg == 'TRIGGER_FENCE':
            content = "```\nFORMATTED-OK\n```"
        else:
            content = "FORMATTED-OK"
        payload = json.dumps({"choices": [{"message": {"content": content}}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *a):
        pass

HTTPServer(('127.0.0.1', 8934), Handler).serve_forever()
PY
python3 "$WORKDIR_TEST/fake_server.py" &
SERVER_PID=$!
sleep 0.5

export VOICETYPE_DIR="$WORKDIR_TEST"
export VOICETYPE_PROMPTS_DIR="$PROMPTS_TEST"
export VOICETYPE_FORMAT_URL="http://127.0.0.1:$PORT/v1/chat/completions"
export VOICETYPE_FORMAT_KEY=""
# shellcheck source=/dev/null
source ./voice-type.sh

assert_eq "successful call returns formatted text" "FORMATTED-OK" "$(format_llm 'hello' 'email')"
assert_eq "code-fence is stripped" "FORMATTED-OK" "$(format_llm 'TRIGGER_FENCE' 'email')"

format_llm 'hello' 'nonexistent-preset' >/dev/null 2>&1
rc=$?
assert_eq "unknown preset returns rc=2" "2" "$rc"

export VOICETYPE_FORMAT_URL="http://127.0.0.1:9999/v1/chat/completions"   # nic tam nie nasłuchuje
format_llm 'hello' 'email' >/dev/null 2>&1
rc=$?
assert_eq "unreachable endpoint returns rc=1" "1" "$rc"

kill "$SERVER_PID" 2>/dev/null
rm -rf "$WORKDIR_TEST" "$PROMPTS_TEST"
exit $FAIL
```

- [ ] **Step 8: Run the mock-server test to verify it fails pre-implementation**

Run: `git stash && bash engine/voice-type-format.test.sh; echo "exit=$?"; git stash pop`
Expected: failures (function `format_llm` doesn't exist yet), `exit=1`, then stash restored.

- [ ] **Step 9: Run the mock-server test against the real implementation**

Run: `bash engine/voice-type-format.test.sh; echo "exit=$?"`
Expected: all `ok -` lines, `exit=0`.

- [ ] **Step 10: Add the new test + shellcheck to CI**

In `.github/workflows/ci.yml`, extend the `shellcheck` job further:

```yaml
      - name: ShellCheck the format test script
        run: shellcheck engine/voice-type-format.test.sh
      - name: Unit tests (format_llm)
        run: bash engine/voice-type-format.test.sh
```

- [ ] **Step 11: Sync the canonical engine to the other 3 macOS copies**

Run the same sync block as Task 1 Step 9.

- [ ] **Step 12: Commit**

```bash
git add engine/voice-type.sh engine/voice-type-format.test.sh prompts/email.txt raycast/assets/voice-type.sh .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
feat(format): add --format post-processing through any OpenAI-compatible LLM

New format_llm() posts the transcript + a file-based system-prompt preset to
VOICETYPE_FORMAT_URL (chat/completions), works with cloud (Groq default) or
local (Ollama/LM Studio) endpoints. --format/VOICETYPE_FORMAT is opt-in and
persisted across the START/STOP toggle like the mic choice already is.
Failure falls back to the raw transcript; an unknown preset name aborts.
Ships one default preset, prompts/email.txt.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Installer + README updates (macOS)

**Files:**
- Modify: `install.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `prompts/email.txt` from Task 2.

- [ ] **Step 1: Find the model-download block in `install.sh` to mirror its idiom**

Run: `grep -n "VAD model" install.sh`

- [ ] **Step 2: Add a "seed default prompt if missing" block**

Immediately after the existing VAD-model download block in `install.sh`, add (using the same if/then/else style as the rest of the file, no `&&`/`||` chains, per the SC2015 CI rule):

```bash
# Seed the default "email" formatting preset — never overwrite an existing (possibly user-edited) file.
PROMPTS_DIR="$HOME/.voicetype/prompts"
if [ ! -f "$PROMPTS_DIR/email.txt" ]; then
  mkdir -p "$PROMPTS_DIR"
  cp "$(dirname "$0")/prompts/email.txt" "$PROMPTS_DIR/email.txt"
fi
```

- [ ] **Step 3: Run shellcheck**

Run: `shellcheck install.sh`
Expected: clean pass.

- [ ] **Step 4: Update `README.md`**

Find the existing env var table (`grep -n "VOICETYPE_VAD_MODEL" README.md` to locate it) and add rows documenting `VOICETYPE_FORMAT`, `VOICETYPE_FORMAT_URL`, `VOICETYPE_FORMAT_MODEL`, `VOICETYPE_FORMAT_KEY`, `VOICETYPE_PROMPTS_DIR`, `VOICETYPE_MIC_PRIORITY`, `VOICETYPE_MIC_AVOID`, plus a short new "## Formatting presets" section explaining `--format <name>`, the `prompts/<name>.txt` convention, and a Keyboard Maestro tip: duplicate your existing macro, change its trigger, and change its shell command to pass `--format email`.

- [ ] **Step 5: Commit**

```bash
git add install.sh README.md
git commit -m "$(cat <<'EOF'
docs+installer: document --format/mic-priority, seed default email preset

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Windows port of `--format`/`format_llm` (mic priority is macOS-only, skip)

**Files:**
- Modify: `windows/voice-type.ps1`
- Modify: `windows/install.ps1`

**Interfaces:**
- Produces: `Format-Llm($text, $preset)` (returns formatted string; throws/returns `$null` on failure — caller distinguishes "unknown preset" from "transient failure" the same way as bash: unknown-preset aborts, transient falls back).

- [ ] **Step 1: Read the current STOP-branch structure to find the exact insertion point**

Run: `grep -n "Test-Phantom \$text\|function Transcribe-Local\|^\\$Prompt " windows/voice-type.ps1`

- [ ] **Step 2: Add format-related config variables**

Near the existing `$Prompt = ...` line, add:

```powershell
$Format      = if ($env:VOICETYPE_FORMAT) { $env:VOICETYPE_FORMAT } else { '' }
$FormatUrl   = if ($env:VOICETYPE_FORMAT_URL) { $env:VOICETYPE_FORMAT_URL } else { 'https://api.groq.com/openai/v1/chat/completions' }
$FormatModel = if ($env:VOICETYPE_FORMAT_MODEL) { $env:VOICETYPE_FORMAT_MODEL } else { 'llama-3.3-70b-versatile' }
$PromptsDir  = if ($env:VOICETYPE_PROMPTS_DIR) { $env:VOICETYPE_PROMPTS_DIR } else { Join-Path $env:USERPROFILE '.voicetype\prompts' }
```

- [ ] **Step 3: Parse `--format` from `$args`**

Near the top of the script (after param/env setup, before the STOP/START branching), add:

```powershell
for ($i = 0; $i -lt $args.Count; $i++) {
  if ($args[$i] -eq '--format' -and ($i + 1) -lt $args.Count) { $Format = $args[$i + 1] }
  elseif ($args[$i] -like '--format=*') { $Format = $args[$i].Substring(9) }
}
```

- [ ] **Step 4: Add `Format-Llm` function**

```powershell
# Formatowanie tekstu przez LLM zgodny z OpenAI /chat/completions. Zwraca @{Ok=$bool; Text=...; Unknown=$bool}
function Format-Llm($text, $preset) {
  $promptFile = Join-Path $PromptsDir "$preset.txt"
  if (-not (Test-Path $promptFile)) { return @{ Ok = $false; Unknown = $true } }
  $sysPrompt = Get-Content $promptFile -Raw -Encoding UTF8
  $key = if ($env:VOICETYPE_FORMAT_KEY) { $env:VOICETYPE_FORMAT_KEY }
         elseif ($env:VOICETYPE_CLOUD_KEY) { $env:VOICETYPE_CLOUD_KEY }
         elseif ($env:GROQ_API_KEY) { $env:GROQ_API_KEY }
         elseif ($env:OPENAI_API_KEY) { $env:OPENAI_API_KEY }
         else { '' }
  $body = @{
    model = $FormatModel
    messages = @(
      @{ role = 'system'; content = $sysPrompt }
      @{ role = 'user'; content = $text }
    )
    temperature = 0.2
  } | ConvertTo-Json -Depth 5
  $headers = @{ 'Content-Type' = 'application/json' }
  if ($key) { $headers['Authorization'] = "Bearer $key" }
  try {
    $resp = Invoke-RestMethod -Uri $FormatUrl -Method Post -Headers $headers -Body $body -TimeoutSec 15
    $out = $resp.choices[0].message.content
    if (-not $out) { return @{ Ok = $false; Unknown = $false } }
    $out = $out -replace '^```[a-zA-Z]*\r?\n', '' -replace '\r?\n```$', ''
    return @{ Ok = $true; Text = $out.Trim() }
  } catch {
    return @{ Ok = $false; Unknown = $false }
  }
}
```

- [ ] **Step 5: Persist `$Format` at START, apply at STOP**

In the START branch, alongside wherever the mic name is persisted to a state file (from the earlier `grep` output), add a sibling line writing `$Format` to `Join-Path $WorkDir 'format'`.

In the STOP branch, right after the existing `if (-not $text -or (Test-Phantom $text)) { Notify ...; exit 0 }` check, add:

```powershell
$stopFormat = ''
$formatFile = Join-Path $WorkDir 'format'
if (Test-Path $formatFile) { $stopFormat = (Get-Content $formatFile -Raw -Encoding UTF8).Trim() }
if ($stopFormat) {
  $result = Format-Llm $text $stopFormat
  if ($result.Ok) {
    $text = $result.Text
  } elseif ($result.Unknown) {
    Notify "❌ nieznany format: $stopFormat"
    exit 0
  } else {
    Notify '⚠️ formatowanie nieudane — wklejono surowy tekst'
  }
}
```

- [ ] **Step 6: Seed default preset in `install.ps1`**

In `windows/install.ps1`, after the VAD-model download block, add:

```powershell
# ── Formatting preset (email) ─────────────────────────────────────────────────
$promptsDir = Join-Path $env:USERPROFILE '.voicetype\prompts'
New-Item -ItemType Directory -Force -Path $promptsDir | Out-Null
$emailPrompt = Join-Path $promptsDir 'email.txt'
if (Test-Path $emailPrompt) { Ok 'Preset email.txt present' }
else { Download "$Raw/prompts/email.txt" $emailPrompt; Ok 'Preset email.txt saved' }
```

- [ ] **Step 7: Verify PowerShell parses cleanly**

Run (matches the CI check): a small local script using `[System.Management.Automation.Language.Parser]::ParseFile` if `pwsh` is available locally; otherwise rely on pushing and checking the `powershell` CI job. Since `pwsh` was previously found unavailable locally (see `2026-07-08` design doc background), push this task's commit and check `gh run list --branch main --limit 3` for the `powershell` job result before proceeding to Task 5.

- [ ] **Step 8: Commit**

```bash
git add windows/voice-type.ps1 windows/install.ps1
git commit -m "$(cat <<'EOF'
feat(windows): port --format LLM post-processing to the PowerShell engine

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
git push origin main
```

Then run: `sleep 15 && gh run list --branch main --limit 1`
Expected: `completed success` for the CI run covering this commit. If the `powershell` job fails, fix and push a follow-up commit before moving on.

---

### Task 5: Raycast "Toggle Dictation — Email" command

**Files:**
- Create: `raycast/src/toggle-email.ts`
- Modify: `raycast/package.json`

**Interfaces:**
- Consumes: same `Prefs` interface, `ENGINE` path, `HISTORY_KEY`/`saveToHistory` pattern from `raycast/src/toggle.ts`.

- [ ] **Step 1: Read `raycast/package.json`'s commands array**

Run: `grep -n '"commands"' -A 20 raycast/package.json`

- [ ] **Step 2: Create `raycast/src/toggle-email.ts`**

Copy `raycast/src/toggle.ts` verbatim except: rename the exported function stays `Command` (Raycast convention — each command file exports a default `Command`), and pass `["--format", "email"]` as argv to `execFile`:

```typescript
import {
  showHUD,
  getPreferenceValues,
  environment,
  LocalStorage,
} from "@raycast/api";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { homedir } from "node:os";
import { existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { HISTORY_KEY } from "./toggle";

const exec = promisify(execFile);

interface Prefs {
  backend: string;
  language: string;
  mic: string;
  prompt: string;
  model: string;
  cloudKey: string;
  cloudUrl: string;
  cloudModel: string;
  deepgramKey: string;
  elevenlabsKey: string;
  paste: boolean;
}

const WORKDIR = join(environment.supportPath, "rec");
const PIDFILE = join(WORKDIR, "ffmpeg.pid");
const ENGINE = join(environment.assetsPath, "voice-type.sh");

function expand(p: string): string {
  return p.startsWith("~") ? join(homedir(), p.slice(1)) : p;
}

function isRecording(): boolean {
  try {
    return existsSync(PIDFILE) && statSync(PIDFILE).size > 0;
  } catch {
    return false;
  }
}

async function saveToHistory(text: string): Promise<void> {
  const raw = await LocalStorage.getItem<string>(HISTORY_KEY);
  const items = raw ? JSON.parse(raw) : [];
  items.unshift({ text, date: Date.now() });
  await LocalStorage.setItem(HISTORY_KEY, JSON.stringify(items.slice(0, 100)));
}

export default async function Command() {
  const prefs = getPreferenceValues<Prefs>();
  const stopping = isRecording();

  await showHUD(
    stopping ? "⏳ Transcribing (email format)…" : "🎙️ Recording for email… (run again to stop)",
  );

  const env = {
    ...process.env,
    PATH: `/opt/homebrew/bin:/usr/local/bin:${join(homedir(), ".local/bin")}:${process.env.PATH ?? ""}`,
    VOICETYPE_DIR: WORKDIR,
    VOICETYPE_BACKEND: prefs.backend || "local",
    VOICETYPE_LANG: prefs.language || "pl",
    VOICETYPE_MIC: prefs.mic || ":default",
    VOICETYPE_PROMPT: prefs.prompt || "",
    VOICETYPE_MODEL: expand(prefs.model),
    VOICETYPE_CLOUD_KEY: prefs.cloudKey || "",
    VOICETYPE_CLOUD_URL: prefs.cloudUrl || "",
    VOICETYPE_CLOUD_MODEL: prefs.cloudModel || "",
    VOICETYPE_DEEPGRAM_KEY: prefs.deepgramKey || "",
    VOICETYPE_ELEVENLABS_KEY: prefs.elevenlabsKey || "",
    VOICETYPE_PASTE: prefs.paste ? "1" : "0",
  };

  try {
    const { stdout } = await exec("/bin/bash", [ENGINE, "--format", "email"], {
      env,
      timeout: 120_000,
    });
    const text = stdout.trim();
    if (stopping && text) {
      await saveToHistory(text);
      await showHUD(`✅ ${text.length > 60 ? text.slice(0, 60) + "…" : text}`);
    }
  } catch (err) {
    await showHUD(`❌ ${err instanceof Error ? err.message : "VoiceType failed"}`);
  }
}
```

- [ ] **Step 3: Export `HISTORY_KEY` from `toggle.ts` (already exported — verify)**

Run: `grep -n "export const HISTORY_KEY" raycast/src/toggle.ts`
Expected: one match (it's already `export const HISTORY_KEY = "voicetype-history";` at line 34 — no change needed, `toggle-email.ts`'s import in Step 2 already relies on this).

- [ ] **Step 4: Register the new command in `raycast/package.json`**

In the `"commands"` array (from Step 1's grep output), add a new entry modeled on the existing `toggle` command entry, e.g.:

```json
    {
      "name": "toggle-email",
      "title": "Toggle Dictation — Email",
      "description": "Start/stop dictation, auto-formatted into a ready-to-paste email",
      "mode": "no-view"
    }
```

- [ ] **Step 5: Sync engine + typecheck + lint**

Run:
```bash
cd raycast
npm run sync-engine
npx tsc --noEmit
npx eslint src
npx prettier --check "src/**/*.{ts,tsx}"
```
Expected: all four commands exit 0 with no errors.

- [ ] **Step 6: Commit**

```bash
git add raycast/src/toggle-email.ts raycast/package.json raycast/assets/voice-type.sh
git commit -m "$(cat <<'EOF'
feat(raycast): add "Toggle Dictation — Email" command bound to its own hotkey

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Windows AHK second hotkey + README (Windows section)

**Files:**
- Modify: `windows/voicetype.ahk`
- Modify: `README.md`

- [ ] **Step 1: Read the current AHK hotkey definition**

Run: `cat windows/voicetype.ahk`

- [ ] **Step 2: Add a second hotkey for email-format dictation**

Following the exact syntax of the existing hotkey line found in Step 1 (same engine invocation pattern, e.g. `Run, powershell -NoProfile -File "%A_ScriptDir%\voice-type.ps1"` or equivalent), add a new hotkey binding — e.g. if the existing one is `#+Space::` (Win+Shift+Space), add `#+e::` (Win+Shift+E) invoking the same script with `--format email` appended to its argument list, matching whatever quoting style the existing line uses.

- [ ] **Step 3: Update `README.md`'s Windows section**

Document the new hotkey and the `VOICETYPE_FORMAT`/`VOICETYPE_FORMAT_*`/`VOICETYPE_PROMPTS_DIR` env vars for Windows users, next to the macOS documentation added in Task 3.

- [ ] **Step 4: Commit and push**

```bash
git add windows/voicetype.ahk README.md
git commit -m "$(cat <<'EOF'
docs+windows: add second AHK hotkey for --format email dictation

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
git push origin main
```

Run: `sleep 15 && gh run list --branch main --limit 1`
Expected: `completed success`.

---

### Task 7: CHANGELOG + Pawel's personal mic config + final end-to-end check

**Files:**
- Modify: `CHANGELOG.md`
- Modify (outside git): `~/.voicetype/config`

**Interfaces:**
- Consumes: `VOICETYPE_MIC_PRIORITY`/`VOICETYPE_MIC_AVOID` from Task 1; `~/.voicetype/prompts/email.txt` seeded by `install.sh`/manually from Task 2/3.

- [ ] **Step 1: Update `CHANGELOG.md`**

Add a bullet to the existing "Initial Version" entry (same unreleased-entry convention used for the VAD-padding fix):

```markdown
- Optional `--format <preset>` post-processing: run the transcript through any OpenAI-compatible chat-completions endpoint (cloud like Groq/OpenAI, or local like Ollama/LM Studio) before pasting — e.g. `--format email` turns free-form dictation into a ready-to-paste email. Presets are plain-text system-prompt files in `~/.voicetype/prompts/`; ships with a default `email` preset. Falls back to the raw transcript on any formatting failure.
- Personal mic override: `VOICETYPE_MIC_PRIORITY`/`VOICETYPE_MIC_AVOID` let you pin a preferred microphone ahead of the macOS system default, and demote another to a last resort — useful when you have multiple inputs (e.g. a desk mic and Bluetooth headset) and don't want macOS's current default to decide.
```

- [ ] **Step 2: Write Pawel's personal mic config**

Check whether `~/.voicetype/config` already exists:

Run: `cat ~/.voicetype/config 2>/dev/null || echo "(does not exist yet)"`

If it doesn't exist, create it; if it does, append (don't clobber existing lines):

```bash
cat >> ~/.voicetype/config <<'EOF'
VOICETYPE_MIC_PRIORITY="PodMic"
VOICETYPE_MIC_AVOID="WH-1000XM4"
EOF
```

- [ ] **Step 3: End-to-end verification — RØDE preferred**

With the RØDE PodMic USB connected (already confirmed present via `ffmpeg -f avfoundation -list_devices` earlier in this conversation), run one real START invocation and confirm the notification names the RØDE device, then stop immediately without speaking (to avoid an unwanted paste) — or inspect `$WORKDIR/mic` directly:

Run:
```bash
VOICETYPE_DIR=/tmp/voicetype-mic-check /Users/pavvel/workspace/scripts/media/voice-type.sh >/dev/null 2>&1
sleep 1
cat /tmp/voicetype-mic-check/mic
/Users/pavvel/workspace/scripts/media/voice-type.sh >/dev/null 2>&1   # stop cleanly
rm -rf /tmp/voicetype-mic-check
```
Expected: prints `RØDE PodMic USB`.

- [ ] **Step 4: Commit the CHANGELOG (personal `~/.voicetype/config` is outside git, not committed)**

```bash
git add CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs(changelog): document --format post-processing and mic priority override

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
git push origin main
```

Run: `sleep 15 && gh run list --branch main --limit 1`
Expected: `completed success`.

- [ ] **Step 5: Update the `voicetype-mic-and-copies` memory file**

Append a note to `/Users/pavvel/.claude/projects/-Users-pavvel-workspace/memory/voicetype-mic-and-copies.md` recording: the new `--format`/`format_llm` feature and its scope (OSS engine only, not the lead magnet), the new `VOICETYPE_MIC_PRIORITY`/`VOICETYPE_MIC_AVOID` mechanism, and Pawel's personal values (`PodMic` / `WH-1000XM4`) living in his local `~/.voicetype/config`. Update the `MEMORY.md` index line for this memory to mention it in ≤150 chars.

## Self-review notes

- **Spec coverage:** CLI `--format` ✅ (Task 2 Step 3), env-var equivalent + persistence across toggle ✅ (Task 2 Steps 1/3/4), pluggable OpenAI-compatible endpoint incl. local models ✅ (Task 2 Step 2, key-optional), generic preset files ✅ (Task 2 Steps 2/6), fallback-to-raw on LLM failure ✅ (Task 2 Step 4), abort on unknown preset ✅ (Task 2 Steps 2/4), mic priority overriding system default ✅ (Task 1 Step 2), mic avoid as last-resort-only ✅ (Task 1 Step 2), separate hotkey wiring for macOS (Raycast, Task 5) and Windows (AHK, Task 6) and KM (documented, Task 3), Windows port of format feature (Task 4), lead-magnet explicitly out of scope (stated in Global Constraints, untouched by any task).
- **Placeholder scan:** no TBD/TODO; every step has literal code or an exact runnable command with an expected result.
- **Type consistency:** `format_llm` return-code contract (0/1/2) is defined once in Task 2 Step 2 and consumed identically in Task 2 Step 4 and mirrored explicitly (as `Ok`/`Unknown` fields) in the PowerShell `Format-Llm` of Task 4 Step 4-5. `resolve_auto_mic`/`is_avoided`/`filter_avoided`/`list_avfoundation_devices` names are used consistently between Task 1 Step 2 and the test script of Task 1 Step 5.
- **Scope check:** each task produces an independently testable/committable deliverable; Task 4 (Windows) explicitly excludes porting mic-priority since that requirement was macOS/personal-only per the spec.
