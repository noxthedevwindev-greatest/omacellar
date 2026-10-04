#!/usr/bin/env bash
# omacellar :: core
# Paths, config, logging, small helpers. Sourced, never executed.

# Guard against double-sourcing heavy work
[[ -n "${_OMACELLAR_CORE:-}" ]] && return 0
_OMACELLAR_CORE=1

OMACELLAR_VERSION="0.1.0"

# ---------------------------------------------------------------- paths ----

omacellar_resolve_root() {
  local src=${BASH_SOURCE[0]} dir
  while [[ -L $src ]]; do
    dir=$(cd -P "$(dirname "$src")" && pwd)
    src=$(readlink "$src")
    [[ $src != /* ]] && src=$dir/$src
  done
  dir=$(cd -P "$(dirname "$src")/.." && pwd)
  printf '%s\n' "$dir"
}

OMACELLAR_ROOT=${OMACELLAR_ROOT:-$(omacellar_resolve_root)}
OMACELLAR_REGISTRY_FILE=${OMACELLAR_REGISTRY_FILE:-$OMACELLAR_ROOT/registry/runners.conf}

: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"

# Everything lives in one hidden directory, so a cache cleaner that only knows
# about ~/.cache and ~/.local/share cannot wipe a cellar or its config.
OMACELLAR_HOME=${OMACELLAR_HOME:-$HOME/.omacellar}

config_file() { printf '%s/config.json\n' "$OMACELLAR_HOME"; }
runners_dir() { _cfg_path runners_dir "$OMACELLAR_HOME/runners"; }
prefixes_dir() { _cfg_path prefix_dir "$OMACELLAR_HOME/prefixes"; }
data_dir() { printf '%s/data\n' "$OMACELLAR_HOME"; }
cache_dir() { printf '%s/data/cache\n' "$OMACELLAR_HOME"; }
downloads_dir() { printf '%s/downloads\n' "$(cache_dir)"; }
api_cache_dir() { printf '%s/api\n' "$(cache_dir)"; }
runner_types_dir() { printf '%s/runner_types\n' "$(data_dir)"; }
version_lists_dir() { printf '%s/version_lists\n' "$(data_dir)"; }
logs_dir() { printf '%s/logs\n' "$(data_dir)"; }

# Every path we ever rm -rf goes through here. An empty or root-ish path is a
# programming error, and refusing loudly beats deleting something expensive.
safe_remove() {
  local d=${1:-}
  [[ -n $d ]] || { log_err "internal: refusing to remove an empty path"; return 1; }
  [[ $d == "/" || $d == "$HOME" || $d == "$OMACELLAR_HOME" ]] && {
    log_err "internal: refusing to remove $d"
    return 1
  }
  [[ -e $d || -L $d ]] || return 0
  rm -rf "$d"
}

_cfg_path() {
  local key=$1 fallback=$2 v
  if [[ -z ${_OMACELLAR_PATHS_READ:-} ]]; then
    _OMACELLAR_PATHS_READ=1
    _CFG_RUNNERS_DIR=$(config_get runners_dir)
    _CFG_PREFIX_DIR=$(config_get prefix_dir)
  fi
  case $key in
    runners_dir) v=${_CFG_RUNNERS_DIR:-} ;;
    prefix_dir) v=${_CFG_PREFIX_DIR:-} ;;
  esac
  printf '%s\n' "${v:-$fallback}"
}

# -------------------------------------------------------------- logging ----

if [[ -t 2 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=; C_DIM=; C_BOLD=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_MAGENTA=; C_CYAN=
fi

log() { printf '%s\n' "$*" >&2; }
log_dim() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }
log_step() { printf '%s==>%s %s\n' "$C_CYAN$C_BOLD" "$C_RESET" "$*" >&2; }
log_ok() { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
log_warn() { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err() { printf '%serr %s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_hint() { printf '%s  -> %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }
die() { log_err "$*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. $2"
}

confirm() {
  local prompt=$1 reply
  [[ -t 0 ]] || return 1
  read -r -p "$prompt [y/N] " reply
  [[ $reply == [yY] || $reply == [yY][eE][sS] ]]
}

# -------------------------------------------------------------- config ----

declare -gA CONFIG=()
declare -g CONFIG_LOADED=false
CONFIG_KEYS="default_runner prefix_dir runners_dir channel keep_versions api_cache_ttl steam_compat_tools runner_env log_level ascii_art"

config_defaults() {
  jq -n '{
    default_runner: "",
    prefix_dir: "",
    runners_dir: "",
    channel: "stable",
    keep_versions: false,
    api_cache_ttl: 21600,
    steam_compat_tools: true,
    runner_env: "",
    log_level: "info",
    ascii_art: true
  }'
}

# Legacy key=value config, imported once into config.json.
legacy_config_file() { printf '%s/omacellar/config\n' "$XDG_CONFIG_HOME"; }

config_legacy_keys() {
  local f; f=$(legacy_config_file)
  [[ -f $f ]] || return 0
  local line key val
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line == *=* ]] || continue
    key=${line%%=*}
    val=${line#*=}
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    val=${val%"${val##*[![:space:]]}"}
    val=${val#"${val%%[![:space:]]*}"}
    val=${val%\"}; val=${val#\"}
    [[ -n $key ]] || continue
    # keep_versions and steam_compat_tools were stored as words, JSON wants
    # booleans, otherwise "false" reads as the truthy string.
    case $val in
      true | false) printf '%s\t%s\n' "$key" "$val" ;;
      *) printf '%s\t%s\n' "$key" "$val" ;;
    esac
  done <"$f"
}

config_init() {
  local f; f=$(config_file)
  mkdir -p "$(dirname "$f")"
  [[ -f $f ]] && return 0

  if [[ -f $(legacy_config_file) ]]; then
    log_step "importing settings from $(legacy_config_file)"
    local imported; imported=$(mktemp)
    {
      printf '{\n'
      local sep="" key val
      while IFS=$'\t' read -r key val; do
        [[ -n $key ]] || continue
        case $val in
          true | false) printf '%s"%s": %s' "$sep" "$key" "$val" ;;
          *) printf '%s"%s": %s' "$sep" "$key" "$(json_str "$val")" ;;
        esac
        sep=$',\n'
      done < <(config_legacy_keys)
      printf '\n}\n'
    } >"$imported"
    # `*` is a shallow merge where the right side wins, so imported goes last.
    if ! jq -s '.[0] * .[1]' <(config_defaults) "$imported" >"$f" 2>/dev/null; then
      config_defaults >"$f"
      log_warn "could not import the old config, wrote defaults instead"
    fi
    rm -f "$imported"
    log_hint "the old file is still at $(legacy_config_file)"
  else
    config_defaults >"$f"
  fi
}

config_load() {
  [[ $CONFIG_LOADED == true ]] && return 0
  config_init
  CONFIG_LOADED=true
  local f; f=$(config_file)
  [[ -f $f ]] || return 0
  local line key val
  while IFS=$'\t' read -r key val; do
    [[ -n $key ]] && CONFIG[$key]=$val
  done < <(jq -r 'to_entries[] | "\(.key)\t\(if .value == true then "true" elif .value == false then "false" else (.value | tostring) end)"' "$f" 2>/dev/null)
  return 0
}

config_get() {
  local key=$1 def=${2:-}
  config_load
  local v=${CONFIG[$key]:-}
  [[ -z $v ]] && v=$def
  printf '%s\n' "$v"
}

config_set() {
  local key=$1 val=$2 f
  config_init
  f=$(config_file)

  # Booleans go in as booleans so a later read is not the string "false".
  local jq_val
  case $val in
    true | false) jq_val=$val ;;
    *) jq_val=$(jq -Rn --arg s "$val" '$s') ;;
  esac

  local tmp; tmp=$(mktemp "${f}.XXXXXX")
  jq --arg k "$key" --argjson v "$jq_val" '.[$k] = $v' "$f" >"$tmp" 2>/dev/null \
    || { rm -f "$tmp"; log_err "config: could not set $key"; return 1; }
  mv -f "$tmp" "$f"
  CONFIG[$key]=$val
  return 0
}

config_unset() {
  local key=$1 f
  config_init
  f=$(config_file)
  local tmp; tmp=$(mktemp "${f}.XXXXXX")
  jq --arg k "$key" 'del(.[$k])' "$f" >"$tmp" 2>/dev/null \
    || { rm -f "$tmp"; log_err "config: could not clear $key"; return 1; }
  mv -f "$tmp" "$f"
  unset 'CONFIG[$key]'
  return 0
}

config_key_known() {
  case " $CONFIG_KEYS " in *" $1 "*) return 0 ;; esac
  return 1
}

# ----------------------------------------------------------------- arch ----

host_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x86_64\n' ;;
    aarch64 | arm64) printf 'aarch64\n' ;;
    *) uname -m ;;
  esac
}

# -------------------------------------------------------------- helpers ----

human_size() {
  local b=${1:-0}
  awk -v b="$b" 'BEGIN{
    split("B KiB MiB GiB TiB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s\n" : "%.1f %s\n"), b, u[i]
  }'
}

human_age() {
  local s=${1:-0}
  if (( s < 90 )); then
    printf '%ds ago\n' "$s"
  elif (( s < 5400 )); then
    printf '%d minutes ago\n' "$(( s / 60 ))"
  elif (( s < 172800 )); then
    printf '%d hours ago\n' "$(( s / 3600 ))"
  else
    printf '%d days ago\n' "$(( s / 86400 ))"
  fi
}

dir_size() {
  local d=$1
  [[ -e $d ]] || { printf '0\n'; return 0; }
  d=$(readlink -f "$d" 2>/dev/null || printf '%s' "$d")
  du -sb "$d" 2>/dev/null | cut -f1
}

version_gt() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" == "$1" && "$1" != "$2" ]]
}

version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" == "$1" ]]
}

free_bytes() {
  df -PB1 "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

sanitize_name() {
  printf '%s\n' "$1" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//'
}

split_spec() {
  local spec=$1
  if [[ $spec == *@* ]]; then
    printf '%s\t%s\n' "${spec%@*}" "${spec#*@}"
  else
    printf '%s\t\n' "$spec"
  fi
}

dir_exists() { [[ -d ${1/#\~/$HOME} ]]; }

ensure_dirs() {
  mkdir -p \
    "$OMACELLAR_HOME" \
    "$(runners_dir)" \
    "$(prefixes_dir)" \
    "$(data_dir)" \
    "$(runner_types_dir)" \
    "$(version_lists_dir)" \
    "$(logs_dir)" \
    "$(downloads_dir)" \
    "$(api_cache_dir)"
  seed_runner_types
  prune_staging
}

# The runner catalogue is data, so it lives in the cellar and is editable by
# hand. The packaged registry is only read once, to seed it.
seed_runner_types() {
  local f; f="$(runner_types_dir)/runners.conf"
  [[ -f $f ]] && return 0
  [[ -f $OMACELLAR_REGISTRY_FILE ]] || return 0
  mkdir -p "$(runner_types_dir)"
  cp "$OMACELLAR_REGISTRY_FILE" "$f"
  log_dim "  seeded the runner catalogue from the packaged registry"
  return 0
}

prune_staging() {
  local root d
  root=$(runners_dir)
  [[ -d $root ]] || return 0
  # Staging and trash sit next to each runner now, so find them at any depth.
  while IFS= read -r d; do
    [[ -d $d ]] || continue
    log_dim "  cleaning up $d"
    safe_remove "$d"
  done < <(find "$root" -maxdepth 3 \( -name '.staging-*' -o -name '.trash-*' \) -type d 2>/dev/null)
  return 0
}

# -------------------------------------------------------------- logging ----

log_session() {
  local f; f="$(logs_dir)/session-$(date +%Y%m%d).log"
  mkdir -p "$(dirname "$f")"
  printf '[%s] %s\n' "$(date -Is)" "$*" >>"$f"
}

# ------------------------------------------------------------ ascii art ----

OMACELLAR_ART='
        ▄▄▄▄▄▄▄▄▄▄▄▄
     ▄█▀▀        ▀▀█▄
   ▄█▀   ▄▄▄▄▄▄▄▄   ▀█▄
  █▀   ▄█▀        ▀█▄   ▀█
 ██   █▀   ▀▀▀▀▀▀   ▀█   ██
 ██   █   ▄▄▄▄▄▄▄   █   ██
 ██   █   █▀▀▀▀▀█   █   ██
 ██   █   █    █   █   ██
 ██   █   █▄▄▄▄▄█   █   ██
 █▀   ▀█▄        ▄█▀   ▀█
  ▀█▄   ▀▀▀▀▀▀▀▀▀▀   ▄█▀
    ▀█▄▄        ▄▄█▀
        ▀▀▀▀▀▀▀▀▀▀▀
'

ascii_art() {
  [[ $(config_get ascii_art true) == false ]] && return 0
  [[ -t 1 ]] || return 0
  printf '%s%s%s\n' "$C_CYAN" "$OMACELLAR_ART" "$C_RESET"
}

ascii_enabled() {
  [[ $(config_get ascii_art true) != false && -t 1 ]]
}