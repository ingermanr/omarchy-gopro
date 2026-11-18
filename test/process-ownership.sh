#!/usr/bin/env bash
# Regression test for process ownership: bin/gopro-webcam must only ever signal the
# ffmpeg it started, never a process rediscovered by searching the process table.
#
# The plugin's shell functions are loaded without running the CLI dispatch, the paths
# they use are redirected to a temporary directory, and real ffmpeg processes stand in
# for "our stream" and for "another ffmpeg session the user happens to run". The stand-in
# processes carry the plugin's device and UDP strings in their command lines, because a
# command line is exactly what the old search-based lookup matched on.
#
# Requires ffmpeg. Exits 77 (skip) when ffmpeg is missing.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v ffmpeg >/dev/null || { echo "skip: ffmpeg not installed"; exit 77; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gopro-webcam-test.XXXXXX")
pass=0 fail=0
pids=""
finish() {
  local pid
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK" || true
  return 0
}
trap finish EXIT

ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
alive() { kill -0 "$1" 2>/dev/null; }

# Load everything above the CLI dispatch: variable defaults plus every function.
sed -n '1,/^cmd=\${1:-start}/p' "$ROOT/bin/gopro-webcam" | sed '$d' > "$WORK/lib.sh"
# shellcheck disable=SC1090
source "$WORK/lib.sh"

DEVICE="$WORK/dev42"
UDP_PORT=8554
FFMPEG_PID_FILE="$WORK/ffmpeg.pid"
STATE="$WORK/state"
RUNTIME_DIR="$WORK"
LOG="$WORK/log"
CAM="http://127.0.0.1:1"
api() { :; }   # no camera traffic in the test

# Fake process command lines: -metadata carries the strings without opening sockets,
# and -re keeps the stand-in processes alive for the duration of the test.
# A foreign ffmpeg that matches the pattern the old search-based lookup used.
foreign() {
  ffmpeg -nostdin -loglevel quiet -re -f lavfi -i testsrc -t 300 \
    -metadata comment="udp://@:${UDP_PORT}" -f null - >/dev/null 2>&1 </dev/null &
  echo $!
}
# The plugin's own stream: same UDP string plus the loopback output device.
own() {
  ffmpeg -nostdin -loglevel quiet -re -f lavfi -i testsrc -t 300 \
    -metadata comment="udp://@:${UDP_PORT}" -metadata title="$DEVICE" \
    -f null - >/dev/null 2>&1 </dev/null &
  echo $!
}
# A live ffmpeg unrelated to the stream, used to simulate a recycled PID.
unrelated() {
  ffmpeg -nostdin -loglevel quiet -re -f lavfi -i testsrc -t 300 -f null - \
    >/dev/null 2>&1 </dev/null &
  echo $!
}

d=$(foreign); pids="$pids $d"; sleep 1
webcam_running && bad "a running stream is claimed without a PID file" \
              || ok "no PID file means no stream, even with a matching foreign ffmpeg"

printf '%s\n' "$d" > "$FFMPEG_PID_FILE"
webcam_running && bad "a recorded PID with a different command line was accepted" \
              || ok "a recorded PID must also match this plugin's own command line"

stop_stream
sleep 0.3
alive "$d" && ok "stop_stream left the foreign ffmpeg alone" \
           || bad "stop_stream killed a foreign ffmpeg"

o=$(own); pids="$pids $o"; sleep 1
printf '%s\n' "$o" > "$FFMPEG_PID_FILE"
[[ $(ffmpeg_pid) == "$o" ]] && ok "the plugin's own ffmpeg is recognised" \
                           || bad "the plugin's own ffmpeg was not recognised"
stop_stream
sleep 0.3
alive "$o" && bad "the plugin's own ffmpeg was not stopped" \
           || ok "the plugin's own ffmpeg is stopped"
[[ -e $FFMPEG_PID_FILE ]] && bad "the PID file survived stop_stream" \
                         || ok "the PID file is removed after stopping"

u=$(unrelated); pids="$pids $u"; sleep 1
printf '%s\n' "$u" > "$FFMPEG_PID_FILE"
stop_stream
sleep 0.3
alive "$u" && ok "a recycled PID that is not the stream is not signalled" \
           || bad "a recycled PID was signalled"

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
(( fail > 0 )) && exit 1
exit 0
