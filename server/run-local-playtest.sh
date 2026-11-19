#!/usr/bin/env bash
set -euo pipefail

mode=${1:-play}
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
if [[ ! -s "$root/.env.playtest" ]]; then
    echo 'Local playtest setup is missing. See the project README.'
    exit 1
fi
IFS= read -r prepared < "$root/.env.playtest"
run="$prepared/ferry-run"
client_project="$root/client"
godot="$prepared/ferry-deps/godot/Godot_v4.5.1-stable_linux.x86_64"
windows_godot="$root/.tools/godot/Godot_v4.5.1-stable_win64"
mongo="$prepared/ferry-deps/mongo/bin/mongod"
server="$run/ferry-server"
mongo_data="$run/database"
[[ "$mode" != second || "${2:-}" != verify ]] || mode=verify-second

if [[ ! -x "$godot" || ! -x "$mongo" || ! -x "$server" ]]; then
    echo 'The local playtest runtimes are missing. See the source README.'
    exit 1
fi
export LD_LIBRARY_PATH="$run/lib"
export FERRY_FONT="/mnt/c/Windows/Fonts/msyh.ttc"
export FERRY_URL="ws://127.0.0.1:7670"
export FERRY_PORT=7670
FERRY_MONGO_DB=animals_playtest
FERRY_BIND=127.0.0.1

exec 9>"$run/boot.lock"
flock 9
if [[ ! -s "$run/players.json" ]]; then
    umask 077
    python3 -c 'import json,secrets; print(json.dumps({name:secrets.token_hex(24) for name in ("tiger-a","tiger-b")}))' > "$run/players.json"
fi
FERRY_PLAYERS=$(cat "$run/players.json")
token_a=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tiger-a"])' "$run/players.json")
token_b=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tiger-b"])' "$run/players.json")

mongo_socket="/tmp/animals-ferry-play-$(id -u).sock"
FERRY_MONGO_URI="mongodb://$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1], safe=""))' "$mongo_socket")/?serverSelectionTimeoutMS=2000&connectTimeoutMS=1500&socketTimeoutMS=2000"
mkdir -p "$mongo_data"
if [[ ! -S "$mongo_socket" ]]; then
    "$mongo" --dbpath "$mongo_data" --bind_ip "$mongo_socket" --port 19774         --filePermissions 0700 --logpath "$run/mongo.log" --pidfilepath "$run/mongo.pid" --fork 9>&-
fi

if [[ ! -s "$run/world.pid" ]] || ! kill -0 "$(cat "$run/world.pid")" 2>/dev/null; then
    FERRY_MONGO_URI="$FERRY_MONGO_URI" FERRY_MONGO_DB="$FERRY_MONGO_DB" FERRY_PLAYERS="$FERRY_PLAYERS" \
        FERRY_BIND="$FERRY_BIND" nohup "$server" "$root/server/lua/world.lua" </dev/null >"$run/world.log" 2>&1 9>&- &
    echo "$!" >"$run/world.pid"
fi
world_pid=$(cat "$run/world.pid")
for attempt in $(seq 1 30); do
    if grep -Fq "Ferry world ready" "$run/world.log" && kill -0 "$world_pid" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$world_pid" 2>/dev/null; then
        cat "$run/world.log"
        exit 1
    fi
    sleep 0.2
done
if ! grep -Fq "Ferry world ready" "$run/world.log"; then
    cat "$run/world.log"
    exit 1
fi
import_dir="$client_project/.godot/imported"
needs_import=false
[[ -d "$import_dir" ]] || needs_import=true
for model in "$client_project"/assets/models/*.glb; do
    [[ -f "$model" ]] || continue
    imported_files=("$import_dir/${model##*/}"-*.scn)
    if [[ ! -f "${imported_files[0]}" || "$model" -nt "${imported_files[0]}" ]]; then
        needs_import=true
        break
    fi
done
if [[ "$needs_import" == true ]]; then
    "$godot" --headless --editor --path "$client_project" --import
fi
flock -u 9
verify=false
[[ "$mode" != verify && "$mode" != verify-second ]] || verify=true
client_godot="$godot"
if [[ -e "${windows_godot}.exe" && -e "${windows_godot}_console.exe" && -d /run/WSL ]]; then
    client_godot="${windows_godot}.exe"
    [[ "$verify" != true ]] || client_godot="${windows_godot}_console.exe"
    # Keep this portable client's logs and shader cache with the local project.
    mkdir -p "$client_project/.godot/local-playtest"
    APPDATA=$(wslpath -w "$client_project/.godot/local-playtest")
    export APPDATA
    client_project=$(wslpath -w "$client_project")
    FERRY_FONT=$(wslpath -w "$FERRY_FONT")
    export WSLENV="${WSLENV:+$WSLENV:}APPDATA:FERRY_URL:FERRY_FONT:FERRY_TOKEN"
fi
token="$token_a"
[[ "$mode" != second && "$mode" != verify-second ]] || token="$token_b"
unset FERRY_PLAYERS FERRY_MONGO_URI FERRY_MONGO_DB
if [[ "$verify" == true ]]; then
    exec env -u FERRY_TOKEN "$client_godot" --headless --path "$client_project" \
        --script res://tests/smoke.gd -- "$FERRY_URL" "$token"
fi
FERRY_TOKEN="$token" exec "$client_godot" --path "$client_project" --resolution 1120x700
