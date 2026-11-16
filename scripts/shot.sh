#!/bin/zsh
# Screenshot (debug build): the app opens in the background (open -g, focus is never taken), DBCLIENT_DEMO sets up the
# screen, the app writes a picture of its own window into its container and quits; the picture is copied to OUT.
# Usage: scripts/shot.sh <name> <screen|-> <dark|light> <language> [connection name]
set -e
NAME=$1; DEMO=$2; THEME=$3; LANG_=$4; CONN=${5:-}
APP=${APP:-${0:A:h:h}/build/dd/Build/Products/Debug/OpenAsy Database Client.app}
OUT=${OUT:-${0:A:h:h}/build/shots}
DIR=~/Library/Containers/com.openasy.database-client.dev/Data/Library/Application\ Support/OpenAsy\ Database\ Client/shots
mkdir -p $OUT
rm -f "$DIR/$NAME.wid"
rm -f "$DIR/$NAME.png"
open -g -n --env DBCLIENT_DEMO=$DEMO --env DBCLIENT_SHOT=$NAME --env DBCLIENT_OPEN=$CONN --env DBCLIENT_LANG=$LANG_ "$APP" --args -theme $THEME
for i in {1..60}; do [[ -f "$DIR/$NAME.png" ]] && ! pgrep -qf "$APP/Contents/MacOS/OpenAsy Database Client" && break; sleep 0.5; done
pkill -f "$APP/Contents/MacOS/OpenAsy Database Client" || true
cp "$DIR/$NAME.png" $OUT/$NAME.png
echo "$OUT/$NAME.png"
