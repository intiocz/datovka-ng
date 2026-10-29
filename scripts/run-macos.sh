#!/bin/sh
# Vývojové okno nad ukázkovými schránkami v app/dev. Skutečný archiv neotevírá.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root/app"
exec flutter run -d macos -t dev/main.dart "$@"
