#!/usr/bin/env bash
# omacellar :: prefixes
# An installation: a Wine prefix pinned to one runner.
#
#   <prefixes_dir>/<name>/drive_c/...
#   <prefixes_dir>/<name>/.omacellar.json

[[ -n "${_OMACELLAR_PREFIX:-}" ]] && return 0
_OMACELLAR_PREFIX=1

PREFIX_META=.omacellar.json

prefix_path() { printf '%s/%s\n' "$(prefixes_dir)" "$1"; }

# The recorded prefix_dir can go stale if the cellar was moved. Fall back to
# the path implied by where the prefix lives now, so a moved cellar still works.
prefix_wine_dir_resolved() {
  local name=$1 root recorded derived
  root=$(prefix_path "$name")
  recorded=$(prefix_meta "$name" prefix_dir)
  derived=$(prefix_wine_dir "$root" "$(prefix_meta "$name" kind wine)")

  if [[ -n $recorded && -f $recorded/system.reg ]]; then
    printf '%s\n' "$recorded"
  elif [[ -f $derived/system.reg ]]; then
    printf '%s\n' "$derived"
  elif [[ -n $recorded ]]; then
    printf '%s\n' "$recorded"
  else
    printf '%s\n' "$derived"
  fi
}

prefix_exists() {
  local wine_root
  wine_root=$(prefix_wine_dir_resolved "$1")
  [[ -f $wine_root/system.reg && -d $wine_root/drive_c ]]
}

# prefix_exists answers yes/no by exit status. This answers with a word, so it
# can be dropped straight into a table or a --json field.
prefix_is_valid() {
  if prefix_exists "$1"; then printf 'true'; else printf 'false'; fi
}

prefix_meta_path() { printf '%s\n' "$(prefix_path "$1")/$PREFIX_META"; }

prefix_meta() {
  local name=$1 key=$2 def=${3:-} p
  p=$(prefix_meta_path "$name")
  [[ -f $p ]] || { printf '%s\n' "$def"; return 0; }
  local v; v=$(jq -r --arg k "$key" '.[$k] // empty' "$p" 2>/dev/null)
  printf '%s\n' "${v:-$def}"
}

prefix_list() {
  local d
  [[ -d $(prefixes_dir) ]] || return 0
  for d in "$(prefixes_dir)"/*/; do
    [[ -d $d ]] || continue
    d=${d%/}
    printf '%s\n' "${d##*/}"
  done | sort
}

prefix_resolve_runner() {
  local want=${1:-}
  if [[ -n $want ]]; then
    # Accepts a full name, a bare id or a prefix, since ids contain dashes.
    local resolved
    if resolved=$(runner_resolve_name "$want"); then
      printf '%s\n' "$resolved"
      return 0
    fi
    log_err "no runner called '$want' is installed"
    log_hint "installed: $(runner_list_installed | tr '\n' ' ')"
    return 1
  fi

  local def; def=$(config_get default_runner)
  if [[ -n $def && -d $(runner_dir_of "$def") ]]; then
    printf '%s\n' "$def"
    return 0
  fi
  [[ -n $def ]] && log_warn "default_runner '$def' is not installed, falling back"

  local first; first=$(prefix_newest_installed_runner || true)
  [[ -n $first ]] || {
    log_err "no runners installed"
    log_hint "omacellar runner add soda"
    return 1
  }
  printf '%s\n' "$first"
}

# Newest installed runner by version, not alphabetically. Ties break on name so
# the answer is stable between runs.
prefix_newest_installed_runner() {
  local -a names=()
  mapfile -t names < <(runner_list_installed)
  [[ ${#names[@]} -gt 0 ]] || return 1
  newest_of "${names[@]}"
}

prefix_newest_install_of() {
  local id=$1 name ver best= bestver=
  while IFS= read -r name; do
    [[ $(runner_meta "$name" id) == "$id" ]] || continue
    ver=$(runner_meta "$name" version)
    if [[ -z $bestver ]] || version_gt "$ver" "$bestver"; then
      best=$name; bestver=$ver
    fi
  done < <(runner_list_installed)
  if [[ -n $best ]]; then
    printf '%s\n' "$best"
    return 0
  fi
  return 1
}

runner_has_win32() {
  local name=$1 dir
  dir=$(runner_dir_of "$name")
  [[ -d $dir/lib/wine/i386-unix || -d $dir/files/lib/wine/i386-unix ]]
}

runner_is_wow64() {
  local name=$1
  runner_installed "$name" && ! runner_has_win32 "$name"
}

prefix_bitness() {
  local dir=$1 arch=
  if [[ -f $dir/system.reg ]]; then
    arch=$(grep -m1 -E '^#arch=' "$dir/system.reg" 2>/dev/null | cut -d= -f2)
  fi
  case $arch in
    win64)
      [[ -d $dir/drive_c/windows/syswow64 ]] && printf 'win32+win64\n' || printf 'win64\n'
      ;;
    win32) printf 'win32\n' ;;
    *)
      if [[ -d $dir/drive_c/windows/syswow64 ]]; then
        printf 'win32+win64\n'
      elif [[ -d $dir/drive_c/windows/system32 ]]; then
        printf 'win64\n'
      else
        printf 'unknown\n'
      fi
      ;;
  esac
}

# ------------------------------------------------------------- problems ----

problem_is_fixable() {
  case $1 in
    prefix_missing_runner | prefix_no_drivec | runner_no_wineserver | steam_broken_link)
      return 0
      ;;
  esac
  return 1
}

problem_message() {
  case $1 in
    prefix_gone) printf 'there is no such installation' ;;
    prefix_missing_runner) printf 'the runner this prefix was built with is gone' ;;
    prefix_no_drivec) printf 'the prefix has no drive_c, so it is not a usable prefix' ;;
    runner_no_wineserver) printf 'the runner has no wineserver, so launches are slow' ;;
    prefix_bitness_mismatch) printf 'a 32-bit prefix on a WoW64 runner' ;;
    steam_broken_link) printf 'Steam has this Proton runner registered at a stale path' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Inspect a prefix and report what is wrong with it.
prefix_problems() {
  local name=$1
  local runner kind bitness dir
  local -a found=()

  # A prefix that does not exist is not a fixable problem, it is a typo or a
  # name that was removed. Say so and stop.
  if [[ ! -d $(prefix_path "$name") ]]; then
    printf 'prefix_gone\n'
    return 0
  fi

  runner=$(prefix_meta "$name" runner)
  kind=$(prefix_meta "$name" kind wine)
  bitness=$(prefix_meta "$name" bitness unknown)
  dir=$(prefix_wine_dir_resolved "$name")
  [[ -d $dir/drive_c ]] || found+=("prefix_no_drivec")

  if [[ -n $runner ]]; then
    if [[ ! -e $(runner_dir_of "$runner") ]]; then
      found+=("prefix_missing_runner")
    else
      runner_wineserver "$(runner_dir_of "$runner")" >/dev/null 2>&1 \
        || found+=("runner_no_wineserver")
      if [[ $bitness == win32 ]] && ! runner_has_win32 "$runner"; then
        found+=("prefix_bitness_mismatch")
      fi
      if [[ $(runner_meta "$runner" kind) == proton ]]; then
        local d
        while IFS= read -r d; do
          [[ -n $d ]] || continue
          if [[ -L $d/$runner && ! -e $d/$runner ]]; then
            found+=("steam_broken_link")
            break
          fi
        done < <(steam_compat_dirs)
      fi
    fi
  fi

  [[ ${#found[@]} -eq 0 ]] || printf '%s\n' "${found[@]}"
  return 0
}

# From errortext.txt: list what we found, say which ones we know how to fix,
# offer the fixable ones, and just report the rest.
prefix_offer_fixes() {
  local name=$1
  local -a problems=()
  mapfile -t problems < <(prefix_problems "$name")

  if [[ ${#problems[@]} -eq 0 ]]; then
    return 0
  fi

  # Not a thing that can be repaired, and not worth a prompt.
  if [[ ${problems[0]} == prefix_gone ]]; then
    log_err "no such prefix: $name"
    log_hint "installed: $(prefix_list | tr '\n' ' ')"
    return 1
  fi

  printf '\n%s%s%s\n' "$C_BOLD$C_YELLOW" "Problems found" "$C_RESET"
  local p
  for p in "${problems[@]}"; do
    printf '%s%s %s%s %s\n' "$C_CYAN" "$C_BOLD" '.' "$C_RESET" "$(problem_message "$p")"
  done

  local -a fixable=()
  for p in "${problems[@]}"; do
    problem_is_fixable "$p" && fixable+=("$p")
  done

  if [[ ${#fixable[@]} -eq 0 ]]; then
    printf '\nomacellar does not know how to fix this.\n'
    printf 'Press enter to exit.\n\n'
    [[ -t 0 ]] && read -r _
    return 1
  fi

  printf '\n%s\n' "omacellar knows how to fix this. Press Y to fix, N to exit."
  printf '\n'

  if [[ -t 0 ]]; then
    printf '%s>%s(y/n) ' "$C_BOLD" "$C_RESET"
    read -r reply
    if [[ $reply == [yY] || $reply == [yY][eE][sS] ]]; then
      prefix_apply_fixes "$name" "${fixable[@]}"
      return $?
    fi
  fi

  printf 'left as it was\n'
  return 1
}

prefix_apply_fixes() {
  local name=$1; shift
  local p rc=0
  for p in "$@"; do
    case $p in
      prefix_no_drivec)
        log_step "rebuilding $name"
        if prefix_create "$name" "$(prefix_meta "$name" runner)" \
          "$(prefix_meta "$name" requested win64)" true >/dev/null; then
          log_ok "rebuilt $name"
        else
          log_err "could not rebuild $name"
          rc=1
        fi
        ;;
      prefix_missing_runner)
        local runner id repl
        runner=$(prefix_meta "$name" runner)
        # The runner is gone, so its metadata is too. Ask the registry what id
        # this name belongs to instead.
        id=$(runner_meta "$runner" id)
        if [[ -z $id ]]; then
          id=$(reg_exists "$runner" && printf '%s' "$runner" || true)
        fi
        if [[ -z $id ]]; then
          id=$(runner_infer_id "$runner" 2>/dev/null || true)
        fi
        if [[ -z $id ]]; then
          log_err "cannot tell which runner '$runner' was, so cannot suggest a replacement"
          log_hint "install one and recreate: omacellar prefix remove $name && omacellar prefix create $name"
          rc=1
          continue
        fi
        log_step "looking for an installed $id to replace $runner"
        runner_index_build
        repl=$(runner_resolve_name "$id" 2>/dev/null || true)
        if [[ -n $repl ]]; then
          local m; m=$(prefix_meta_path "$name")
          local tmp; tmp=$(mktemp)
          jq --arg r "$repl" '.runner = $r' "$m" >"$tmp" && mv -f "$tmp" "$m"
          log_ok "$name now points at $repl"
          log_hint "prefixes are runner specific, expect friction until it is recreated"
        else
          log_err "no runner with id '$id' is installed, install one first"
          rc=1
        fi
        ;;
      runner_no_wineserver)
        log_warn "nothing to fix here, this runner just ships without one"
        ;;
      steam_broken_link)
        runner_register_steam "$(prefix_meta "$name" runner)" || rc=1
        ;;
      *)
        log_warn "no handler for $p"
        ;;
    esac
  done
  return $rc
}

prefix_create() {
  local name=$1 runner=$2 arch=${3:-win64} force=${4:-false}
  local dir; dir=$(prefix_path "$name")

  if prefix_exists "$name" && [[ $force == false ]]; then
    log_err "prefix '$name' already exists"
    log_hint "use --force to recreate it from scratch (this deletes the old one)"
    return 1
  fi

  case $arch in
    win64 | win32 | both) ;;
    *) log_err "unknown architecture '$arch' (want win64, win32 or both)"; return 1 ;;
  esac
  local requested=$arch

  local kind; kind=$(runner_kind_of "$runner")

  case $arch in
    win32)
      if [[ $kind == proton ]]; then
        log_err "proton runners only build 64-bit containers"
        log_hint "use: omacellar prefix create $name --runner $runner"
        return 1
      fi
      if ! runner_has_win32 "$runner"; then
        log_err "$runner is a WoW64 build and refuses WINEARCH=win32"
        log_hint "its 64-bit prefixes still run 32-bit programs, so use:"
        log_hint "  omacellar prefix create $name --runner $runner --arch win64"
        return 1
      fi
      ;;
    both)
      arch=win64
      log_dim "  a win64 prefix on $runner already runs 32-bit programs"
      ;;
  esac

  local runner_root; runner_root=$(runner_dir_of "$runner")
  local wine_bin; wine_bin=$(runner_wine_bin "$runner_root") || {
    log_err "runner '$runner' has no wine binary"
    return 1
  }

  if [[ $force == true && -d $dir ]]; then
    safe_remove "$dir"
  fi
  mkdir -p "$dir"

  local winedir; winedir=$(prefix_wine_dir "$dir" "$kind")

  log_step "creating $name with $runner ($arch)"
  log_dim "  prefix: $winedir"

  local log_file; log_file=$(mktemp)

  if [[ $kind == proton ]]; then
    log_dim "  proton runinprefix wineboot -u"
    if ! launch_run "$runner" "$dir" direct "$runner_root/proton" \
      runinprefix wineboot -u >"$log_file" 2>&1; then
      log_err "proton failed to build the prefix"
      sed 's/^/    /' "$log_file" >&2
      rm -f "$log_file"
      return 1
    fi
  else
    local wineserver
    wineserver=$(runner_wineserver "$runner_root") || wineserver=$wine_bin
    local -a base_env=(
      "WINE=$wine_bin"
      "WINELOADER=$wine_bin"
      "WINESERVER=$wineserver"
      "WINEPREFIX=$winedir"
    )
    [[ -n ${WINEDEBUG:-} ]] && base_env+=("WINEDEBUG=$WINEDEBUG")
    mkdir -p "$winedir"

    log_dim "  wineboot -u ($arch)"
    if ! env "${LAUNCH_ENV_UNSET[@]}" "${base_env[@]}" "WINEARCH=$arch" \
      "$wine_bin" wineboot -u >"$log_file" 2>&1; then
      log_err "wineboot failed"
      sed 's/^/    /' "$log_file" >&2
      rm -f "$log_file"
      log_hint "WINEDEBUG=+channel omacellar prefix create ... for more detail"
      return 1
    fi
  fi
  rm -f "$log_file"

  local bitness; bitness=$(prefix_bitness "$winedir")
  local reported; reported=$(runner_probe_version "$runner_root")

  jq -n --arg name "$name" --arg runner "$runner" --arg kind "$kind" \
    --arg arch "$arch" --arg requested "$requested" --arg bitness "$bitness" \
    --arg created_at "$(date -Is)" --arg runner_version "$reported" \
    --arg prefix_dir "$winedir" \
    '{name:$name, runner:$runner, kind:$kind, arch:$arch, requested:$requested,
      bitness:$bitness, created_at:$created_at, runner_version:$runner_version,
      prefix_dir:$prefix_dir}' >"$dir/$PREFIX_META"

  log_ok "created $name ($bitness)"
  printf '%s\n' "$dir"
}

prefix_remove() {
  local name=$1 assume_yes=${2:-false}
  local dir; dir=$(prefix_path "$name")
  [[ -d $dir ]] || { log_err "no such prefix: $name"; return 1; }

  log_dim "  $name occupies $(human_size "$(dir_size "$dir")")"
  if [[ $assume_yes != true ]]; then
    confirm "Delete prefix '$name' and everything in it?" || { log_dim "kept $name"; return 0; }
  fi
  safe_remove "$dir" || return 1
  log_ok "removed $name"
}

prefix_resolve_program() {
  local name=$1 prog=$2 winedir
  winedir=$(prefix_wine_dir_resolved "$name")

  local cmd=$prog
  case $prog in
    [A-Za-z]:\\* | [A-Za-z]:/*)
      ;;
    */*)
      if [[ -e $prog ]]; then
        cmd=$prog
      elif [[ -e $winedir/$prog ]]; then
        cmd="$winedir/$prog"
      else
        die "no such program: $prog (looked in $winedir too)"
      fi
      ;;
  esac
  printf '%s\n' "$cmd"
}

prefix_run() {
  local name=$1; shift
  [[ -d $(prefix_path "$name") ]] || { log_err "no such prefix: $name"; return 1; }
  [[ $# -gt 0 ]] || { log_err "no program given"; return 1; }

  local runner; runner=$(prefix_meta "$name" runner)
  [[ -n $runner ]] || { log_err "prefix '$name' has no runner recorded"; return 1; }
  [[ -d $(runner_dir_of "$runner") ]] || {
    log_err "the runner '$runner' this prefix was built with is gone"
    log_hint "reinstall it, or point the prefix at another one: omacellar prefix info $name"
    return 1
  }

  local dir; dir=$(prefix_path "$name")
  local winedir; winedir=$(prefix_wine_dir_resolved "$name")

  local program; program=$(prefix_resolve_program "$name" "$1"); shift

  launch_run "$runner" "$dir" wine "$program" "$@"
}

prefix_winetricks() {
  local name=$1; shift
  [[ -d $(prefix_path "$name") ]] || { log_err "no such prefix: $name"; return 1; }
  need_cmd winetricks "Install the 'winetricks' package."
  if [[ $# -eq 0 ]]; then
    command -v zenity >/dev/null 2>&1 || {
      log_err "no verbs given and zenity is not installed, so no --gui"
      log_hint "omacellar prefix winetricks $name corefonts"
      return 1
    }
    set -- --gui
  fi

  local runner; runner=$(prefix_meta "$name" runner)
  local dir; dir=$(prefix_path "$name")

  log_step "winetricks $* -> $name"
  launch_run "$runner" "$dir" direct winetricks "$@"
}

prefix_shell() {
  local name=$1 term=${2:-}
  [[ -d $(prefix_path "$name") ]] || { log_err "no such prefix: $name"; return 1; }

  if [[ -z $term ]]; then
    for c in foot alacritty ghostty kitty wezterm; do
      command -v "$c" >/dev/null 2>&1 && { term=$c; break; }
    done
  fi
  [[ -n $term ]] || { log_err "no terminal emulator found, try: omacellar prefix shell $name <terminal>"; return 1; }

  local runner; runner=$(prefix_meta "$name" runner)
  local dir; dir=$(prefix_path "$name")

  local envs; envs=$(launch_print_env "$runner" "$dir")
  log_step "opening a shell in $name ($term)"
  case $term in
    foot) exec foot --title="omacellar: $name" -c "eval '$envs'; exec \$SHELL" ;;
    alacritty) exec alacritty --title "omacellar: $name" -e bash -c "eval '$envs'; exec \$SHELL" ;;
    ghostty) exec ghostty --title="omacellar: $name" -e bash -c "eval '$envs'; exec \$SHELL" ;;
    kitty) exec kitty --title "omacellar: $name" bash -c "eval '$envs'; exec \$SHELL" ;;
    *) exec "$term" ;;
  esac
}