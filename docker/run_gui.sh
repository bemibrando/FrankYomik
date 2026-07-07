#!/usr/bin/env bash
# Launch the Frank Yomik Linux client under Xvfb, exposed via noVNC on :6080.
# App data (vocab, settings) persists to $HOME (=/appdata, a mounted volume).
set -e
export DISPLAY=:0
export HOME=/appdata
export LIBGL_ALWAYS_SOFTWARE=1

mkdir -p "$HOME/.config" "$HOME/.cache"

# Seed the server connection on first run so the app auto-connects.
# FRANK_SERVER_URL / FRANK_AUTH_TOKEN are provided by docker-compose. The app's
# support-dir name differs between release ("FrankYomik") and debug
# ("com.frankmanga.frank_client") builds, so seed both.
seed_prefs() {
  mkdir -p "$1"
  [ -f "$1/shared_preferences.json" ] && return 0
  cat > "$1/shared_preferences.json" <<JSON
{"flutter.server_url":"${FRANK_SERVER_URL:-http://api:8080}","flutter.auth_token":"${FRANK_AUTH_TOKEN:-mysecrettoken}","flutter.pipeline":"manga_furigana","flutter.target_language":"en","flutter.auto_translate":true}
JSON
}
seed_prefs "$HOME/.local/share/FrankYomik"
seed_prefs "$HOME/.local/share/com.frankmanga.frank_client"

rm -f /tmp/.X0-lock
Xvfb :0 -screen 0 1360x900x24 >/tmp/xvfb.log 2>&1 &
sleep 1.5
fluxbox >/tmp/fluxbox.log 2>&1 &
x11vnc -display :0 -nopw -forever -shared -bg -rfbport 5900 >/tmp/x11vnc.log 2>&1
websockify --web=/usr/share/novnc 6080 localhost:5900 >/tmp/novnc.log 2>&1 &
sleep 1

# Bundle layout differs between the Dockerfile build (/app/FrankYomik) and a
# raw `flutter build` tree — find the executable either way.
BIN="$( [ -x /app/FrankYomik ] && echo /app/FrankYomik || find /app -maxdepth 5 -type f -name FrankYomik | head -1 )"
cd "$(dirname "$BIN")"
echo "GUI up on :6080  ($BIN)  server=${FRANK_SERVER_URL:-http://api:8080}"
exec "$BIN" >/tmp/app.log 2>&1
