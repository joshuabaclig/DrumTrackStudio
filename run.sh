#!/usr/bin/env bash
# Start Drum Track Studio (macOS / Linux). No arguments opens the window;
# with a URL it runs in the terminal instead - see  ./run.sh --help
cd "$(dirname "$0")"
[ -x env/bin/python ] || { echo 'Run ./setup.sh first.' >&2; exit 1; }
exec env/bin/python -m drumtrackstudio "$@"
