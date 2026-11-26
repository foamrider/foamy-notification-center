#!/bin/bash
# foamy-kit 0.14.1 2f585065dffcce41c2ad5712118ce3f4f1e19d8801c537025cb389a40f1b7ad5 — do not edit; change foamy-kit and run sync
# Bounded clipboard read for a field that must never let Qt paste itself.
#
#   bash kit/clipboard.sh clipboard|primary [multiline]
#
# Prints the selection's text as one JSON string on stdout: line breaks as
# spaces, or with `multiline` (a multi-line field) as "\n" (CR LF, CR,
# U+2028 and U+2029 each become one "\n"). Exit 0 on success; 5 when the
# text is over 16 KiB or contains NUL; 137 when the 2 s deadline killed the
# read; 143 when the caller stopped it (TERM, INT or HUP: the whole read is
# killed, as it is when this script itself is killed, SIGKILL included);
# 2 for a bad argument; any other nonzero code when wl-paste failed
# (no Wayland display, nothing copied, no text type). Read stdout only after
# exit 0: a failed wl-paste still leaves "" there. Nothing is written to
# stderr.
set -euo pipefail

case ${1:-} in
  clipboard | primary)
    [[ $# == 1 || ($# == 2 && $2 == multiline) ]] || exit 2
    # The guard kills the read when this wrapper ends before the read does,
    # however it ends: Quickshell kills the wrapper with SIGKILL, which no
    # trap sees, when its Process is destroyed (a closed field, a reload).
    # Only this wrapper and, until it starts timeout, the read's job hold
    # the guard's pipe open, so its end of file comes exactly then. The job
    # writes its pid there first; "done" (on exit, after the read has been
    # waited for) means there is nothing left to kill. timeout leads its own
    # process group once it runs: kill its pid too, in case it has not yet.
    exec {guard}> >(
      # A stop sent to the whole process group (a closed terminal, a session
      # that ends) reaches the guard too: it must outlive the wrapper to kill
      # the read, which timeout has moved to a group of its own.
      trap '' TERM INT HUP
      exec >/dev/null 2>&1
      job=
      while read -r line && [[ $line != "done" ]]; do
        job=$line
      done
      [[ $line == "done" || -z $job ]] || kill -KILL -- "$job" "-$job"
    )
    trap 'printf "done\n" >&"$guard"' EXIT
    # A stop (TERM, INT or HUP) skips "done", so the guard kills the read.
    trap 'trap - EXIT; exit 143' TERM INT HUP
    # Kill the whole read-only pipeline at its deadline, including a
    # producer that ignores TERM. This still bounds the read if the guard
    # is killed too.
    {
      printf '%s\n' "$BASHPID" >&"$guard"
      exec timeout --signal=KILL 2s bash "$0" _read "$@" {guard}>&-
    } &
    wait "$!" 2>/dev/null
    ;;
  _read)
    [[ ($# == 2 || ($# == 3 && $3 == multiline)) && ($2 == clipboard || $2 == primary) ]] || exit 2
    options=(--no-newline --type text)
    [[ $2 != primary ]] || options+=(--primary)
    multiline=false
    [[ ${3:-} != multiline ]] || multiline=true
    # Read one extra byte to reject oversized input instead of silently truncating it.
    wl-paste "${options[@]}" 2>/dev/null | head -c 16385 | jq -Rse --argjson multiline "$multiline" '
      if utf8bytelength > 16384 or contains("\u0000") then
        error("Clipboard text exceeds the limit or contains NUL")
      elif $multiline then
        gsub("\r\n|[\r\u2028\u2029]"; "\n")
      else
        gsub("[\r\n\u2028\u2029]"; " ")
      end
    ' 2>/dev/null
    ;;
  *) exit 2 ;;
esac
