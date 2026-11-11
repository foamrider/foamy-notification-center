#!/bin/bash
# foamy-notification-center's own tests; tests/validate.sh runs this after the
# linters.
#   --ci    no Quickshell, no Omarchy host: the node tests and the host-free
#           Python tests (the helper runs as a process from bin/x86_64; the
#           ones that need magick or inotifywait are skipped without them)
#   --fast  skip the Quickshell runtime tests
# Without --ci the helper suites also run the aarch64 build under
# qemu-aarch64-static when it is installed, and settings-ui and images-ui run
# when a Wayland session is there (they take real keyboard focus meanwhile).
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1
ci=0 fast=0
for arg in "$@"; do
  case $arg in
    --ci) ci=1 ;;
    --fast) fast=1 ;;
    *)
      echo "suite.sh: unknown argument $arg" >&2
      exit 2
      ;;
  esac
done
export FOAMY_KIT=${FOAMY_KIT:-$HOME/GitHub/Personal/foamy-kit}
status=0
run() {
  echo "== $*"
  "$@" || status=1
}
skip() { echo "SKIP $*"; }

# The helper's image and watch paths run magick and inotifywait (README
# "Requires"); CI images may not have them.
tools=1
for tool in magick inotifywait file; do
  command -v "$tool" >/dev/null || tools=0
done
needs_tools='magick|inotifywait'
for test in tests/*.test.js tests/*.test.cjs; do
  if ((ci && ! tools)) && grep -Eq "$needs_tools|helper\.cjs" "$test"; then
    skip "$test: the helper needs magick, inotifywait and file"
    continue
  fi
  run node --test "$test"
done
run python3 -I -m unittest discover -s tests -p '*_test.py'

helper=bin/aarch64/foamy-notification-center-helper
if ((ci)); then
  skip "the aarch64 helper: host test (qemu-aarch64-static)"
elif command -v qemu-aarch64-static >/dev/null; then
  prefix="[\"$(command -v qemu-aarch64-static)\",\"$PWD/$helper\"]"
  FOAMY_HELPER=$prefix run node --test tests/contract.test.js tests/integration.test.js
  FOAMY_HELPER=$prefix run python3 -I -m unittest discover -s tests -p 'favicon_test.py'
else
  skip "the aarch64 helper: no qemu-aarch64-static"
fi

if ((ci || fast)); then
  skip "the Quickshell runtime tests (browser-ui, rtl-rows, scrolling, settings-number, motion, stock-runtime, i18n_runtime, images-ui, settings-ui)"
  exit $status
fi
unset LD_LIBRARY_PATH
for test in browser-ui rtl-rows scrolling settings-number motion stock-runtime; do
  run python3 "tests/$test.py"
done
run python3 tests/stock-runtime.py --custom
run python3 "$FOAMY_KIT/preview/i18n_runtime.py" .
if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
  run python3 tests/images-ui.py
  run python3 tests/settings-ui.py
else
  skip "images-ui, settings-ui: no Wayland session"
fi
exit $status
