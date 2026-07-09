#!/bin/bash
# Testy jednostkowe dla resolve_auto_mic()/is_avoided()/filter_avoided() —
# źródłuje silnik (dzięki run-guard nie odpala prawdziwego nagrywania) i
# podstawia fake'i pod default_input_name/list_avfoundation_devices.
# shellcheck disable=SC2329,SC2034,SC2317  # fakes/globals used indirectly by sourced resolve_auto_mic()
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

FAIL=0
assert_eq() { # $1=opis $2=oczekiwane $3=otrzymane
  if [ "$2" = "$3" ]; then
    echo "ok - $1"
  else
    echo "FAIL - $1: expected '$2', got '$3'"
    FAIL=1
  fi
}

VOICETYPE_DIR="$(mktemp -d)"
export VOICETYPE_DIR
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
