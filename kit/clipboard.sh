#!/bin/bash
# foamy-kit 0.3.3 5084c8e33fd38e0ba57b1cf2b732cd04a4985d714583f7445e45419d95ae3118 — do not edit; change foamy-kit and run sync
set -euo pipefail

case ${1:-} in
  clipboard|primary)
    # Keep the watchdog separate: it still bounds the pipeline if Quickshell
    # kills this wrapper during reload/destruction. Kill the whole read-only
    # pipeline at its deadline, including a producer that ignores TERM.
    timeout --signal=KILL 2s bash "$0" _read "$1" &
    clipboard_job=$!
    trap 'kill -KILL -- "-$clipboard_job" 2>/dev/null || true; wait "$clipboard_job" 2>/dev/null || true; exit 143' TERM INT HUP
    wait "$clipboard_job" 2>/dev/null
    ;;
  _read)
    [[ $# == 2 && ( $2 == clipboard || $2 == primary ) ]] || exit 2
    options=(--no-newline --type text)
    [[ $2 != primary ]] || options+=(--primary)
    # Read one extra byte to reject oversized input instead of silently truncating it.
    wl-paste "${options[@]}" 2>/dev/null | head -c 16385 | jq -Rse '
      if utf8bytelength > 16384 or contains("\u0000") then
        error("Clipboard text exceeds the limit or contains NUL")
      else
        gsub("[\r\n\u2028\u2029]"; " ")
      end
    ' 2>/dev/null
    ;;
  *) exit 2 ;;
esac
