#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/script/version.sh"
MODE="${1:-run}"
case "$MODE" in
  run|--build-only|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *) echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
# Build-only does not interrupt an open document window.
if [[ "$MODE" != --build-only ]] && pgrep -x "$CANONSCAN_EXECUTABLE" >/dev/null; then
  pkill -TERM -x "$CANONSCAN_EXECUTABLE" || true
  for attempt in {1..30}; do
    if ! pgrep -x "$CANONSCAN_EXECUTABLE" >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x "$CANONSCAN_EXECUTABLE" >/dev/null; then
    echo 'Bitte das offene Dokumentfenster schließen und erneut starten.' >&2
    exit 1
  fi
fi
APP="$ROOT/dist/$CANONSCAN_APP_NAME.app"
"$ROOT/script/build_app.sh" debug "$APP"
[[ "$MODE" != --build-only ]] || exit 0
case "$MODE" in
  run) /usr/bin/open -n "$APP" ;;
  --debug|debug) lldb -- "$APP/Contents/MacOS/$CANONSCAN_EXECUTABLE" ;;
  --logs|logs)
    /usr/bin/open -n "$APP"
    /usr/bin/log stream --info --style compact --predicate 'process == "CanonScan"' ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "de.r3d.CanonScan"' ;;
  --verify|verify)
    /usr/bin/open -n "$APP"
    sleep 1
    pgrep -x "$CANONSCAN_EXECUTABLE" >/dev/null
    echo 'R3Ds CanonScan gestartet.' ;;
esac
