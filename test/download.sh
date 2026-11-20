#!/usr/bin/env bash
# Regression test for "download": the camera file must end up as a regular file at
# exactly <dir>/<name>, and anything else that appears at that name must make the
# download fail instead of reporting success.
#
# Camera traffic is stubbed: media_paths lists one file and curl writes fixed bytes,
# optionally changing the destination while the "download" runs.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gopro-download-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

sed -n '1,/^cmd=\${1:-start}/p' "$ROOT/bin/gopro-webcam" | sed '$d' > "$WORK/lib.sh"
# shellcheck disable=SC1090
source "$WORK/lib.sh"
set +e   # lib.sh enables errexit; assertions must keep running after a failure
CAM="http://127.0.0.1:1"
NAME=GX010001.MP4
media_paths() { echo "100GOPRO/$NAME"; }
# Race hook run by the fake curl after it wrote the temporary file.
race() { :; }
curl() {
  local out=""
  while (( $# )); do [[ $1 == -o ]] && { out=$2; shift; }; shift; done
  printf 'video-bytes' > "$out"
  race
}

# Each case gets a fresh destination directory; "download" exits, so run it in a subshell.
run() { DIR=$(mktemp -d "$WORK/dest.XXXXXX"); ( download "$NAME" "$DIR" ) >"$WORK/out" 2>&1; }
leftovers() { compgen -G "$DIR/.gopro-download.*" >/dev/null || compgen -G "$DIR/$NAME/.gopro-download.*" >/dev/null; }

race() { :; }
run; rc=$?
[[ $rc == 0 && -f $DIR/$NAME && ! -L $DIR/$NAME && $(<"$DIR/$NAME") == video-bytes ]] \
  && ok "a plain download lands as a regular file" || bad "a plain download failed (rc=$rc)"

race() { :; }
DIR=$(mktemp -d "$WORK/dest.XXXXXX"); echo old > "$DIR/$NAME"
( download "$NAME" "$DIR" ) >"$WORK/out" 2>&1; rc=$?
[[ $rc != 0 && $(<"$DIR/$NAME") == old ]] \
  && ok "an existing file is not replaced" || bad "an existing file was replaced (rc=$rc)"

race() { mkdir "$DIR/$NAME"; }
run; rc=$?
if [[ $rc != 0 ]] && ! leftovers; then ok "a directory appearing at the destination fails the download"
else bad "a directory appearing at the destination was reported as success (rc=$rc)"; fi

race() { mkdir "$WORK/elsewhere.$$" 2>/dev/null; ln -s "$WORK/elsewhere.$$" "$DIR/$NAME"; }
run; rc=$?
if [[ $rc != 0 && -z $(ls -A "$WORK/elsewhere.$$") ]] && ! leftovers; then
  ok "a symlink to a directory appearing at the destination fails the download"
else bad "a symlink to a directory at the destination was followed (rc=$rc)"; fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
(( fail > 0 )) && exit 1
exit 0
