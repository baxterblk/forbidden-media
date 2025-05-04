#!/usr/bin/env bash
# inject_plex_libraries.sh v1.3.8
#
# Purpose: Safely transfer selected library sections from a fixed base Plex instance
#          into a target Plex instance (partial injection) or fully clone the
#          entire Plex config (if "all" selected), preserving metadata,
#          thumbnails, databases, and settings—skipping initial scans.
#          After injection, triggers Plex to refresh the library via API.
#
# Usage: ./inject_plex_libraries.sh -t TARGET_CONTAINER_ID [-b BASE_CONTAINER_ID] [-d]
#   -t: Target Plex container ID or name (required)
#   -b: Base Plex container ID or name (optional)
#   -d: Debug mode (optional)

set -eo pipefail

# ====== CONFIGURATION ======
DEFAULT_BASE_CONTAINER="base_image_container_name"
SUPPORT_DIR="Library/Application Support/Plex Media Server"
DB_SUBDIR="Plug-in Support/Databases"
META_SUBDIR="Metadata"

BASE_CONTAINER_NAME="$DEFAULT_BASE_CONTAINER"
WORK_DIR="/tmp/plex_inject_$RANDOM"
BASE_DB_PATH="$WORK_DIR/base_db"
TARGET_DB_PATH="$WORK_DIR/target_db"

DEBUG=0
DEBUG_LOG="$WORK_DIR/debug.log"
BASE_STOPPED=0
SELECT_ALL=0
SELECT_IDS=()
TARGET_CONTAINER=""

# ====== UTILS ======
timestamp(){ date '+%Y-%m-%d %H:%M:%S'; }
log(){ echo "[$(timestamp)] $*"; }
info(){ log "INFO: $*"; }
warn(){ log "WARNING: $*"; }
error(){ log "ERROR: $*"; exit 1; }
debug(){ [[ "$DEBUG" -eq 1 ]] && { log "DEBUG: $*"; mkdir -p "$(dirname "$DEBUG_LOG")"; echo "[$(timestamp)] [DEBUG] $*" >> "$DEBUG_LOG"; }; }

cleanup(){
  info "Cleaning up temporary files"
  rm -rf "$WORK_DIR"
}

restart_target(){
  if [[ -n "$TARGET_CONTAINER" ]]; then
    info "Ensuring target container $TARGET_CONTAINER is running"
    docker start "$TARGET_CONTAINER" >/dev/null 2>&1 || warn "Failed to restart target container"
  fi
}
trap 'restart_target; cleanup' EXIT

check_requirements(){
  command -v sqlite3 >/dev/null || error "sqlite3 is required."
  command -v docker   >/dev/null || error "docker is required."
}

resolve_container(){
  local name="$1" cid
  cid=$(docker ps -aqf "name=^${name}$" 2>/dev/null || true)
  [[ -z "$cid" ]] && cid=$(docker ps -aqf "name=${name}" 2>/dev/null || true)
  [[ -z "$cid" && $(docker inspect "$name" &>/dev/null; echo $?) -eq 0 ]] && cid="$name"
  [[ -z "$cid" ]] && return 1
  echo "$cid"
}

get_config_path(){
  local c="$1" src
  src=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$c" 2>/dev/null)
  [[ -n "$src" && -d "$src" ]] && echo "$src" && return 0
  return 1
}

extract_base(){
  local container="$1" dest="$2"
  info "Extracting base config from $container → $dest"
  mkdir -p "$dest/$DB_SUBDIR" "$dest/$META_SUBDIR"
  local cfg
  cfg=$(get_config_path "$container") || error "Cannot get base config path"
  cp -av "$cfg/$SUPPORT_DIR/$DB_SUBDIR/"* "$dest/$DB_SUBDIR/"
  cp -av "$cfg/$SUPPORT_DIR/$META_SUBDIR/"* "$dest/$META_SUBDIR/"
}

extract_target_db(){
  local container="$1" dest="$2"
  info "Extracting target library DB → $dest"
  mkdir -p "$dest"
  local dir="/config/$SUPPORT_DIR/$DB_SUBDIR"
  local dbfile
  dbfile=$(docker exec "$container" sh -c "find \"$dir\" -maxdepth 1 -type f -name 'com.plexapp.plugins.library.db' | head -1")
  [[ -z "$dbfile" ]] && error "Cannot locate library DB in target"
  docker cp "$container:$dbfile" "$dest/"
}

interactive_select(){
  echo
  mapfile -t entries < <(sqlite3 -separator '|' "$BASE_DB_PATH/$DB_SUBDIR/com.plexapp.plugins.library.db" \
    "SELECT id||'|'||name FROM library_sections ORDER BY id;")
  declare -A idx2id
  for i in "${!entries[@]}"; do
    local id=${entries[$i]%%|*}
    local nm=${entries[$i]#*|}
    printf " %d. %s (ID %s)\n" $((i+1)) "$nm" "$id"
    idx2id[$((i+1))]="$id"
  done
  echo
  read -rp "Enter numbers to inject, or 'all' for full clone: " sel
  [[ "${sel,,}" == "all" ]] && { SELECT_ALL=1; return; }
  IFS=',' read -ra picks <<< "$sel"
  for p in "${picks[@]}"; do [[ -n "${idx2id[$p]}" ]] && SELECT_IDS+=("${idx2id[$p]}"); done
}

refresh_plex(){
  local dir host_cfg token
  host_cfg=$(get_config_path "$TARGET_CONTAINER")
  # retrieve plex token
  token=$(docker exec "$TARGET_CONTAINER" cat "/config/$SUPPORT_DIR/plex.token" 2>/dev/null || echo)
  if [[ -z "$token" ]]; then warn "No Plex token found; skipping API refresh"; return; fi
  if [[ "$SELECT_ALL" -eq 1 ]]; then
    info "Refreshing all library sections via Plex API"
    docker exec "$TARGET_CONTAINER" curl -s -X POST "http://127.0.0.1:32400/library/sections/all/refresh?X-Plex-Token=$token" >/dev/null
  else
    for id in "${SELECT_IDS[@]}"; do
      info "Refreshing section ID $id via Plex API"
      docker exec "$TARGET_CONTAINER" curl -s -X POST "http://127.0.0.1:32400/library/sections/$id/refresh?X-Plex-Token=$token" >/dev/null
    done
  fi
}

main(){
  local OPTIND opt TARGET_NAME BASE_OVERRIDE
  while getopts "t:b:d" opt; do case "$opt" in
    t) TARGET_NAME="$OPTARG";; b) BASE_OVERRIDE="$OPTARG";; d) DEBUG=1;; esac; done
  [[ -z "$TARGET_NAME" ]] && error "-t TARGET_CONTAINER is required"
  [[ -n "$BASE_OVERRIDE" ]] && BASE_CONTAINER_NAME="$BASE_OVERRIDE"

  check_requirements
  TARGET_CONTAINER=$(resolve_container "$TARGET_NAME") || error "Cannot resolve target"
  BASE_CONTAINER=$(resolve_container "$BASE_CONTAINER_NAME") || error "Cannot resolve base"
  info "Base: $BASE_CONTAINER, Target: $TARGET_CONTAINER"
  read -rp "Stop base container '$BASE_CONTAINER'? [Y/n]: " ans
  [[ ! "${ans,,}" =~ ^n ]] && { docker stop "$BASE_CONTAINER" >/dev/null; BASE_STOPPED=1; }

  extract_base "$BASE_CONTAINER" "$BASE_DB_PATH"
  extract_target_db "$TARGET_CONTAINER" "$TARGET_DB_PATH"
  interactive_select

  local cfg_dir host_db_dir
  cfg_dir=$(get_config_path "$TARGET_CONTAINER") || error "Cannot get target config"
  host_db_dir=$(find "$cfg_dir/$SUPPORT_DIR" -type d -path "*${DB_SUBDIR}" | head -1)
  [[ -z "$host_db_dir" ]] && error "Cannot locate host DB dir"

  if [[ "$SELECT_ALL" -eq 1 ]]; then
    info "Performing full clone of config..."
    docker stop "$TARGET_CONTAINER" >/dev/null
    cp -av "$BASE_DB_PATH/$DB_SUBDIR/"* "$host_db_dir/"
    mkdir -p "$cfg_dir/$SUPPORT_DIR/$META_SUBDIR"
    cp -av "$BASE_DB_PATH/$META_SUBDIR/"* "$cfg_dir/$SUPPORT_DIR/$META_SUBDIR/"
    # restore ownership
    owner=$(stat -c "%u:%g" "$host_db_dir/com.plexapp.plugins.library.db")
    chown -R $owner "$host_db_dir" "$cfg_dir/$SUPPORT_DIR/$META_SUBDIR"
    docker start "$TARGET_CONTAINER" >/dev/null
    [[ "$BASE_STOPPED" -eq 1 ]] && docker start "$BASE_CONTAINER" >/dev/null
    refresh_plex
    echo "Full clone complete. Plex will start with preloaded library."
    exit 0
  fi

  info "Wiping existing sections in target DB"
  sqlite3 "$TARGET_DB_PATH/com.plexapp.plugins.library.db" <<SQL
DELETE FROM section_locations; DELETE FROM library_sections;
SQL

  info "Injecting selected sections..."
  for id in "${SELECT_IDS[@]}"; do
    sqlite3 "$TARGET_DB_PATH/com.plexapp.plugins.library.db" <<SQL
INSERT INTO library_sections SELECT * FROM "$BASE_DB_PATH/$DB_SUBDIR/com.plexapp.plugins.library.db".library_sections WHERE id=$id;
SQL
    sqlite3 "$TARGET_DB_PATH/com.plexapp.plugins.library.db" <<SQL
INSERT INTO section_locations SELECT * FROM "$BASE_DB_PATH/$DB_SUBDIR/com.plexapp.plugins.library.db".section_locations WHERE library_section_id=$id;
SQL
  done

  info "Merging metadata tables..."
  for tbl in metadata_items metadata_parts; do
    sqlite3 "$TARGET_DB_PATH/com.plexapp.plugins.library.db" <<SQL
INSERT OR IGNORE INTO $tbl SELECT * FROM "$BASE_DB_PATH/$DB_SUBDIR/com.plexapp.plugins.library.db".$tbl;
SQL
  done

  docker stop "$TARGET_CONTAINER" >/dev/null
  cp -av "$TARGET_DB_PATH/"* "$host_db_dir/"
  owner=$(stat -c "%u:%g" "$host_db_dir/com.plexapp.plugins.library.db")
  chown -R $owner "$host_db_dir"
  docker start "$TARGET_CONTAINER" >/dev/null
  [[ "$BASE_STOPPED" -eq 1 ]] && docker start "$BASE_CONTAINER" >/dev/null
  refresh_plex
  echo "Injection complete. Plex will start with updated libraries and metadata."
}

main "$@"