#!/usr/bin/env bash
# =============================================================================
# Easy installer for ALE (AzerothCore Lua Engine) - https://github.com/azerothcore/mod-ale
#
# Usage:
#   ./install-ale.sh                       # auto-detect the AzerothCore folder
#   ./install-ale.sh /path/to/azerothcore  # point at it yourself
#   ./install-ale.sh --remove [path]       # remove the module again
#
# What it does:
#   1. Finds your AzerothCore source folder (the one that has a "modules" dir)
#   2. Clones (or updates) mod-ale into modules/
#   3. Warns about the old mod-eluna / mod-eluna-lua-engine (they conflict)
#   4. Creates a lua_scripts folder with a test script
#   5. Optionally rebuilds (Docker or native)
#
# Safe to re-run. Nothing outside the AzerothCore folder is touched.
# =============================================================================
set -euo pipefail

REPO_URL="https://github.com/azerothcore/mod-ale.git"
MOD_NAME="mod-ale"

c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_bold=$'\033[1m'; c_off=$'\033[0m'
info()  { echo "${c_green}==>${c_off} $*"; }
warn()  { echo "${c_yellow}WARNING:${c_off} $*"; }
fail()  { echo "${c_red}ERROR:${c_off} $*" >&2; exit 1; }
ask()   { # ask "question" default(y/n)
  local prompt="$1" def="${2:-y}" reply
  read -r -p "$prompt [$([ "$def" = y ] && echo Y/n || echo y/N)] " reply || true
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

# ---- args -------------------------------------------------------------------
REMOVE=0
AC_DIR=""
for arg in "$@"; do
  case "$arg" in
    --remove) REMOVE=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) AC_DIR="$arg" ;;
  esac
done

command -v git >/dev/null 2>&1 || fail "git is not installed. Install it first (Steam Deck: see note below)."

# ---- find the AzerothCore folder ---------------------------------------------
is_ac_dir() { [ -d "$1/modules" ] && { [ -f "$1/CMakeLists.txt" ] || [ -d "$1/src/server" ] || [ -f "$1/acore.sh" ]; }; }

if [ -z "$AC_DIR" ]; then
  info "Looking for your AzerothCore folder..."
  candidates=()
  for base in "$PWD" "$HOME" "$HOME/Documents" "$HOME/Games" "/home/deck" "/run/media" "/mnt"; do
    [ -d "$base" ] || continue
    while IFS= read -r d; do
      is_ac_dir "$d" && candidates+=("$d")
    done < <(find "$base" -maxdepth 4 -type d -name modules -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | sed 's|/modules$||')
  done
  # de-duplicate
  mapfile -t candidates < <(printf '%s\n' "${candidates[@]:-}" | awk 'NF && !seen[$0]++')

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "Couldn't find it automatically."
    read -r -p "Paste the full path to your AzerothCore folder: " AC_DIR
  elif [ "${#candidates[@]}" -eq 1 ]; then
    AC_DIR="${candidates[0]}"
    info "Found: $AC_DIR"
    ask "Use this one?" y || { read -r -p "Paste the full path instead: " AC_DIR; }
  else
    echo "Found several. Pick one:"
    select choice in "${candidates[@]}" "Enter a path manually"; do
      if [ "$choice" = "Enter a path manually" ]; then
        read -r -p "Path: " AC_DIR
      else
        AC_DIR="$choice"
      fi
      break
    done
  fi
fi

AC_DIR="${AC_DIR/#\~/$HOME}"
AC_DIR="$(cd "$AC_DIR" 2>/dev/null && pwd)" || fail "That folder doesn't exist."
is_ac_dir "$AC_DIR" || fail "$AC_DIR doesn't look like an AzerothCore source folder (no modules/ directory)."

MODULES_DIR="$AC_DIR/modules"
TARGET="$MODULES_DIR/$MOD_NAME"

# ---- remove mode -------------------------------------------------------------
if [ "$REMOVE" -eq 1 ]; then
  [ -d "$TARGET" ] || fail "$MOD_NAME is not installed in $MODULES_DIR"
  ask "Delete $TARGET ?" n || exit 0
  rm -rf "$TARGET"
  info "Removed. Rebuild your server to finish (your lua_scripts folder was left alone)."
  exit 0
fi

# ---- conflicts -----------------------------------------------------------------
for old in mod-eluna mod-eluna-lua-engine mod-LuaEngine; do
  if [ -d "$MODULES_DIR/$old" ]; then
    warn "Old Lua module found: modules/$old"
    echo "  ALE replaces it. Running both will break the build, and old Eluna scripts"
    echo "  may need porting because the APIs have diverged."
    if ask "  Move it aside to modules/$old.disabled (not deleted)?" y; then
      mv "$MODULES_DIR/$old" "$MODULES_DIR/$old.disabled"
      info "Moved $old out of the way. (A .disabled folder inside modules/ is ignored by CMake only"
      echo "   if it has no CMakeLists in the top level; if the build complains, move it outside modules/.)"
    else
      fail "Can't continue with both installed."
    fi
  fi
done

# ---- clone / update ------------------------------------------------------------
if [ -d "$TARGET/.git" ]; then
  info "$MOD_NAME already present - updating..."
  git -C "$TARGET" pull --ff-only
elif [ -e "$TARGET" ]; then
  fail "$TARGET exists but isn't a git checkout. Move or delete it and re-run."
else
  info "Cloning $MOD_NAME..."
  git clone "$REPO_URL" "$TARGET"
fi

# ---- scripts folder + test script ------------------------------------------------
echo
info "Where should your Lua scripts live?"
echo "  ALE reads this from its config file (mod_ale.conf, option for the scripts path)."
echo "  Check the config after install to confirm the exact setting name."
DEFAULT_SCRIPTS="$AC_DIR/lua_scripts"
read -r -p "Scripts folder [$DEFAULT_SCRIPTS]: " SCRIPTS_DIR
SCRIPTS_DIR="${SCRIPTS_DIR:-$DEFAULT_SCRIPTS}"
mkdir -p "$SCRIPTS_DIR"

TEST_SCRIPT="$SCRIPTS_DIR/ale_hello.lua"
if [ ! -f "$TEST_SCRIPT" ]; then
  cat > "$TEST_SCRIPT" <<'LUA'
-- ALE test script: prints a line to the worldserver log on startup.
-- Delete this file once you've confirmed ALE works.
print("[ALE] Hello from ale_hello.lua - Lua engine is running!")
LUA
  info "Created test script: $TEST_SCRIPT"
fi

# ---- config reminder -------------------------------------------------------------
CONF_DIST="$(find "$TARGET" -maxdepth 3 -name 'mod_ale.conf.dist' 2>/dev/null | head -n1 || true)"
if [ -n "$CONF_DIST" ]; then
  info "Config template: $CONF_DIST"
  echo "   After building, copy it to your server's configs/modules/ as mod_ale.conf"
  echo "   (if Yu'lon/Docker manages your config, use its Tuning tab or raw file editor)."
fi

# ---- rebuild ---------------------------------------------------------------------
echo
echo "${c_bold}Module installed. The server must be rebuilt for ALE to take effect.${c_off}"
echo "How do you run your server?"
echo "  1) Docker (docker compose)"
echo "  2) Native build (cmake + make)"
echo "  3) Skip - I'll rebuild myself (e.g. with Yu'lon's Rebuild button)"
read -r -p "Choose 1-3 [3]: " mode
mode="${mode:-3}"

case "$mode" in
  1)
    command -v docker >/dev/null 2>&1 || fail "docker not found."
    COMPOSE_DIR=""
    for d in "$AC_DIR" "$(dirname "$AC_DIR")"; do
      for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [ -f "$d/$f" ] && { COMPOSE_DIR="$d"; break 2; }
      done
    done
    [ -n "$COMPOSE_DIR" ] || fail "Couldn't find a docker-compose file near $AC_DIR."
    info "Building with docker compose in $COMPOSE_DIR (this can take a long time)..."
    (cd "$COMPOSE_DIR" && docker compose build && docker compose up -d)
    ;;
  2)
    BUILD_DIR="$AC_DIR/build"
    mkdir -p "$BUILD_DIR"
    info "Configuring (Lua 5.2 is the default; see the mod-ale README for other versions)..."
    (cd "$BUILD_DIR" && cmake ../ -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        ${ALE_CMAKE_ARGS:-} && make -j"$(nproc)" && make install)
    ;;
  *)
    info "Skipping rebuild."
    ;;
esac

echo
info "Done!"
echo "Next steps:"
echo "  * Rebuild / restart the server if you skipped that."
echo "  * Check the worldserver log for the line from ale_hello.lua."
echo "  * Put your own .lua scripts in: $SCRIPTS_DIR"
echo
echo "Missing lua.h errors? Install Lua dev headers, e.g. on Debian/Ubuntu: sudo apt install liblua5.2-dev"
echo "Steam Deck note: if git is missing, run 'sudo steamos-readonly disable' first, or use the"
echo "  git that ships with Yu'lon's environment / distrobox."
