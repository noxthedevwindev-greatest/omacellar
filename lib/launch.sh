#!/usr/bin/env bash
# omacellar :: launch
# Turns a runner plus a prefix into a process with the right environment.

[[ -n "${_OMACELLAR_LAUNCH:-}" ]] && return 0
_OMACELLAR_LAUNCH=1

declare -ga LAUNCH_ENV=()
LAUNCH_ENV_CLEAR=(WINEPREFIX WINEDLLPATH WINELOADER WINESERVER WINE WINEARCH
  STEAM_COMPAT_DATA_PATH STEAM_COMPAT_CLIENT_INSTALL_PATH)

declare -ga LAUNCH_ENV_UNSET_BASE=()
for _v in "${LAUNCH_ENV_CLEAR[@]}"; do
  LAUNCH_ENV_UNSET_BASE+=(-u "$_v")
done
unset _v
declare -ga LAUNCH_ENV_UNSET=("${LAUNCH_ENV_UNSET_BASE[@]}")

# Runner ids contain dashes (soda-dev, proton-ge, kron4ek-tkg), so
# "<id>-<version>" cannot be split on the first dash to find the directory. The
# index built from the filesystem is the only reliable way back.
declare -gA RUNNER_PATH=()

runner_index_build() {
  local root id dir key
  root=$(runners_dir)
  RUNNER_PATH=()
  [[ -d $root ]] || return 0
  for id in "$root"/*; do
    # A linked runner is a symlink sitting directly in runners/, adopted from
    # somewhere else on disk, so it is keyed by its own name.
    if [[ -L $id ]]; then
      RUNNER_PATH[$(basename "$id")]=$id
      continue
    fi
    [[ -d $id ]] || continue
    local base=${id##*/}
    for dir in "$id/New"/*/; do
      [[ -d $dir ]] || continue
      dir=${dir%/}
      RUNNER_PATH["$base-${dir##*/}"]=$dir
    done
  done
  return 0
}

runner_dir_of() {
  local name=$1
  if [[ -n ${RUNNER_PATH[$name]:-} ]]; then
    printf '%s\n' "${RUNNER_PATH[$name]}"
    return 0
  fi
  # Not indexed: either nothing is installed or the caller wants a path that
  # does not exist yet. Guess from the shape and let the caller's -d test fail.
  printf '%s/%s\n' "$(runners_dir)" "$name"
}

# Runner ids contain dashes, so "<id>-<version>" cannot be split reliably. The
# id is passed in explicitly wherever the caller already knows it, and derived
# from the directory layout only as a fallback.
runner_id_of() {
  local name=$1
  local dir; dir=$(runner_dir_of "$name")
  # runners/<id>/New/<version> -> <id>. Anything else is its own name.
  if [[ $(basename "$(dirname "$dir")") == New ]]; then
    printf '%s\n' "$(basename "$(dirname "$(dirname "$dir")")")"
  else
    printf '%s\n' "$name"
  fi
  return 0
}

runner_old_dir_of() {
  printf '%s/%s/Old\n' "$(runners_dir)" "$1"
}

runner_new_dir_of() {
  printf '%s/%s/New\n' "$(runners_dir)" "$1"
}

runner_kind_of() {
  local name=$1 kind
  kind=$(runner_meta "$name" kind)
  if [[ -z $kind ]]; then
    kind=$(runner_detect_kind "$(runner_dir_of "$name")" 2>/dev/null) || return 1
  fi
  printf '%s\n' "$kind"
}

runner_wine_bin() {
  local dir=$1
  for c in "$dir/bin/wine" "$dir/files/bin/wine" "$dir/bin/wine64"; do
    [[ -x $c ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

runner_wineserver() {
  local dir=$1
  for c in "$dir/bin/wineserver" "$dir/files/bin/wineserver"; do
    [[ -x $c ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

prefix_wine_dir() {
  local prefix=$1 kind=${2:-wine}
  if [[ $kind == proton ]]; then
    printf '%s/pfx\n' "$prefix"
  else
    printf '%s\n' "$prefix"
  fi
}

launch_build_env() {
  local name=$1 prefix=${2:-} kind dir
  dir=$(runner_dir_of "$name")
  [[ -d $dir ]] || { log_err "no such runner: $name"; return 1; }
  kind=$(runner_kind_of "$name") || { log_err "cannot tell how to launch $name"; return 1; }

  LAUNCH_ENV=()
  LAUNCH_ENV_UNSET=("${LAUNCH_ENV_UNSET_BASE[@]}")

  local wine_bin wineserver
  wine_bin=$(runner_wine_bin "$dir") || { log_err "$name has no wine binary"; return 1; }
  wineserver=$(runner_wineserver "$dir") || wineserver=$wine_bin

  local bindir=${wine_bin%/*}
  LAUNCH_ENV+=("PATH=$bindir:$PATH")

  if [[ $kind == proton ]]; then
    [[ -n $prefix ]] && LAUNCH_ENV+=(
      "STEAM_COMPAT_DATA_PATH=$prefix"
      "STEAM_COMPAT_CLIENT_INSTALL_PATH=$prefix"
      "WINEPREFIX=$prefix/pfx"
    )
  elif [[ -n $prefix ]]; then
    LAUNCH_ENV+=("WINEPREFIX=$prefix")
  fi

  LAUNCH_ENV+=(
    "WINE=$wine_bin"
    "WINELOADER=$wine_bin"
    "WINESERVER=$wineserver"
    "OMACELLAR_RUNNER=$name"
    "OMACELLAR_PREFIX=$prefix"
  )

  if [[ $kind == proton ]]; then
    LAUNCH_ENV_UNSET+=(-u __GLX_VENDOR_LIBRARY_NAME)
  fi

  if [[ -n ${WINEDEBUG:-} ]]; then
    LAUNCH_ENV+=("WINEDEBUG=$WINEDEBUG")
  fi
  if [[ -n ${WINEDLLOVERRIDES:-} ]]; then
    LAUNCH_ENV+=("WINEDLLOVERRIDES=$WINEDLLOVERRIDES")
  fi

  local extra; extra=$(config_get runner_env)
  if [[ -n $extra ]]; then
    while IFS= read -r line; do
      [[ -z $line || $line == \#* ]] && continue
      [[ $line == *=* ]] && LAUNCH_ENV+=("$line")
    done <<<"$extra"
  fi

  LAUNCH_ENV_KIND=$kind
  LAUNCH_ENV_DIR=$dir
  LAUNCH_ENV_BIN=$wine_bin
  return 0
}

launch_print_env() {
  local name=$1 prefix=${2:-}
  launch_build_env "$name" "$prefix" || return 1
  local entry key
  for entry in "${LAUNCH_ENV[@]}"; do
    key=${entry%%=*}
    printf 'export %s=%q\n' "$key" "${entry#*=}"
  done
}

launch_run() {
  local name=$1 prefix=${2:-} mode=${3:-direct}
  shift 3
  [[ $# -gt 0 ]] || { log_err "no command given"; return 1; }
  launch_build_env "$name" "$prefix" || return 1

  local -a env_args=()
  local entry
  for entry in "${LAUNCH_ENV[@]}"; do
    env_args+=("$entry")
  done

  local -a target=()
  case $mode in
    direct)
      target=("$@")
      ;;
    wine)
      if [[ $LAUNCH_ENV_KIND == proton ]]; then
        [[ -n $prefix ]] || {
          log_err "proton runners need a prefix: omacellar prefix run <prefix> <program>"
          return 1
        }
        [[ -n ${STEAM_COMPAT_APP_ID:-} ]] && env_args+=("STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID")
        target=("$LAUNCH_ENV_DIR/proton" runinprefix "$@")
      else
        target=("$LAUNCH_ENV_BIN" "$@")
      fi
      ;;
    *)
      log_err "internal: unknown launch mode '$mode'"
      return 1
      ;;
  esac

  env "${LAUNCH_ENV_UNSET[@]}" "${env_args[@]}" "${target[@]}"
}