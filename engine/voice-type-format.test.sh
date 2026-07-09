#!/bin/bash
# Test format_llm() end-to-end przeciw lokalnemu fake OpenAI-compatible serwerowi (python3 http.server),
# bez potrzeby prawdziwego klucza API.
# shellcheck disable=SC2034  # FORMAT_URL used indirectly by sourced format_llm()
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

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

VOICETYPE_DIR="$WORKDIR_TEST"
VOICETYPE_PROMPTS_DIR="$PROMPTS_TEST"
VOICETYPE_FORMAT_URL="http://127.0.0.1:$PORT/v1/chat/completions"
VOICETYPE_FORMAT_KEY=""
export VOICETYPE_DIR VOICETYPE_PROMPTS_DIR VOICETYPE_FORMAT_URL VOICETYPE_FORMAT_KEY
# shellcheck source=/dev/null
source ./voice-type.sh

assert_eq "successful call returns formatted text" "FORMATTED-OK" "$(format_llm 'hello' 'email')"
assert_eq "code-fence is stripped" "FORMATTED-OK" "$(format_llm 'TRIGGER_FENCE' 'email')"

format_llm 'hello' 'nonexistent-preset' >/dev/null 2>&1
rc=$?
assert_eq "unknown preset returns rc=2" "2" "$rc"

export VOICETYPE_FORMAT_URL="http://127.0.0.1:9999/v1/chat/completions"   # nic tam nie nasłuchuje
FORMAT_URL="$VOICETYPE_FORMAT_URL"
format_llm 'hello' 'email' >/dev/null 2>&1
rc=$?
assert_eq "unreachable endpoint returns rc=1" "1" "$rc"

{ kill "$SERVER_PID" && wait "$SERVER_PID"; } 2>/dev/null
rm -rf "$WORKDIR_TEST" "$PROMPTS_TEST"
exit $FAIL
