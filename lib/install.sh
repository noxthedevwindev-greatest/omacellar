#!/usr/bin/env bash
# omacellar :: runner installation
#
# Layout on disk:
#   $runners_dir/<id>-<version>/          unpacked runner
#   $runners_dir/<id>-<version>/.omacellar.json   metadata written by us
#
# Every install lands in a staging directory first and is moved into place with
# a single rename, so an interrupted download never leaves a half runner behind.

[[ -n "${_OMACELLAR_INSTALL:-}" ]] && return 0
_OMACELLAR_INSTALL=1

OMACELLAR_META=.omacellar.json
OMACELLAR_META_DIR=.omacellar-meta
OMACELLAR_VERSION_FILE=.omacellar-version

# ---------------------------------------------------------- update offer ----

# On boot, ask whether to move the runner a prefix is about to use up to the
# latest published version. Matches errortext.txt: a dot, the runner name, and
# old/new versions coloured.
# Prints the runner to use on stdout. Called from a command substitution, so
# every prompt and progress line goes to stderr and the answer is read from
# /dev/tty, otherwise the user never sees the question.
offer_runner_update() {
  local want=${1:-}
  local runner
  runner=$(prefix_resolve_runner "$want" 2>/dev/null) || return 0

  local id installed latest
  id=$(runner_meta "$runner" id)
  [[ -n $id ]] || return 0
  reg_exists "$id" || return 0

  local source; source=$(runner_meta "$runner" source)
  case $source in
    local | adopted) return 0 ;;
  esac

  installed=$(runner_true_version "$runner")
  latest=$(runner_latest_version "$id" 2>/dev/null | cut -f1)
  [[ -n $latest ]] || return 0
  version_gt "$latest" "$installed" || return 0

  local title; title=$(reg_title "$id")
  {
    log_step "update for a runner"
    printf '%sNew version detected for the runner below.%s\n' "$C_BOLD" "$C_RESET"
    printf 'Do you want to update to the latest runner?\n'
    printf '%s%s%s %s%s%s %s(old %s%s%s / %s%s%s%s)\n' \
      "$C_CYAN" "$C_BOLD" '.' "$C_RESET" "$C_BOLD" "$title" "$C_RESET" "$C_DIM" \
      "$C_RED" "$installed" "$C_RESET" "$C_DIM" \
      "$C_GREEN" "$latest" "$C_RESET"
    printf '\n'
  } >&2

  # --yes is checked first: an unattended caller asked not to be prompted, and on
# a machine with no controlling terminal there is nothing to answer anyway.
  local do_update=false
  if [[ ${ASSUME_YES:-false} == true ]]; then
    do_update=true
  elif tty_can_prompt; then
    printf '%s>%s(y/n) ' "$C_BOLD" "$C_RESET" >&2
    local reply=
    read -r reply </dev/tty || reply=
    [[ $reply == [yY] || $reply == [yY][eE][sS] ]] && do_update=true
  else
    log_dim "  (no terminal to ask on, keeping $installed)"
  fi

  if [[ $do_update == true ]]; then
    log_step "updating $title to $latest"
    if with_lock runner_install "$id" "$latest" --force >/dev/null; then
      log_ok "$title is now $latest"
      printf '%s\n' "$id-$latest"
      return 0
    fi
    log_warn "update failed, carrying on with $installed"
  fi

  printf '%s\n' "$runner"
  return 0
}

# ------------------------------------------------------- concurrency lock ----

# One install at a time per cellar. Two `runner add` runs racing on the same
# staging path used to clobber each other.
with_lock() {
  local f; f="$(runners_dir)/.lock"
  mkdir -p "$(runners_dir)"
  if ! command -v flock >/dev/null 2>&1; then
    "$@"
    return $?
  fi
  exec {__oc_lock_fd}>"$f" || { "$@"; return $?; }
  if ! flock -w 900 "$__oc_lock_fd"; then
    log_err "another omacellar is holding the cellar lock, giving up"
    return 1
  fi
  "$@"
  local rc=$?
  exec {__oc_lock_fd}>&-
  return $rc
}

runner_meta_path() {
  local name=$1 root dir
  root=$(runners_dir)
  dir=$(runner_dir_of "$name")
  # Metadata for a linked runner lives in the cellar, not in someone else's
  # directory, so the cellar has to stay writable even when it does not.
  if [[ -L $dir ]]; then
    printf '%s/%s/%s.json\n' "$root" "$OMACELLAR_META_DIR" "$name"
  else
    printf '%s/%s' "$dir" "/$OMACELLAR_META"
  fi
}

runner_installed() { [[ -d "$(runners_dir)/$1" ]]; }

runner_meta() {
  local name=$1 key=$2 def=${3:-} line v=
  runner_meta_load "$name"
  while IFS=$'\t' read -r k v; do
    if [[ $k == "$key" ]]; then
      printf '%s\n' "${v:-$def}"
      return 0
    fi
  done <<<"${_OMACELLAR_META[:$name]}"
  printf '%s\n' "$def"
}

# Active runners: every version directory under <id>/New/.
runner_list_installed() {
  local root; root=$(runners_dir)
  [[ -d $root ]] || return 0
  local e id dir
  for e in "$root"/*; do
    # A linked runner is a symlink at the top level, keyed by its own name.
    if [[ -L $e ]]; then
      printf '%s\n' "${e##*/}"
      continue
    fi
    [[ -d $e ]] || continue
    id=${e%/}
    for dir in "$id/New"/*/; do
      [[ -d $dir ]] || continue
      dir=${dir%/}
      printf '%s-%s\n' "${id##*/}" "${dir##*/}"
    done
  done | sort
}

# Kept-but-not-active versions, one "<id><TAB><version>" per line. Ids contain
# dashes and versions do too, so the two fields are never reassembled by string
# surgery. Old/ directories are not in the runner index, so this walks the tree.
runner_list_old() {
  local root; root=$(runners_dir)
  [[ -d $root ]] || return 0
  local id dir
  for id in "$root"/*/; do
    [[ -d $id ]] || continue
    id=${id%/}
    for dir in "$id/Old"/*/; do
      [[ -d $dir ]] || continue
      dir=${dir%/}
      printf '%s\t%s\n' "${id##*/}" "${dir##*/}"
    done
  done | sort -t$'\t' -k1,1 -k2,2Vr
}

# The on-disk path of a kept version, from id and version separately.
runner_old_path_of() {
  printf '%s/%s/Old/%s\n' "$(runners_dir)" "$1" "$2"
}

runner_list_ids() {
  local root; root=$(runners_dir)
  [[ -d $root ]] || return 0
  local e id
  for e in "$root"/*; do
    [[ -d $e/New ]] || continue
    id=${e%/}
    printf '%s\n' "${id##*/}"
  done | sort
}

runner_is_linked() {
  local dir; dir=$(runner_dir_of "$1")
  [[ -L $dir ]]
}

# Accept a full name (<id>-<version>), a bare id, or a unique prefix, and print
# the installed runner it means. Ids contain dashes and versions are optional,
# so this resolves against what is actually installed rather than guessing at a
# string split.
runner_resolve_name() {
  local want=$1 name
  [[ -n $want ]] || return 1

  runner_index_build

  if [[ -n ${RUNNER_PATH[$want]:-} ]]; then
    printf '%s\n' "$want"
    return 0
  fi

  local -a exact=() by_id=() partial=()
  for name in "${!RUNNER_PATH[@]}"; do
    if [[ $(runner_meta "$name" id) == "$want" ]]; then
      by_id+=("$name")
    elif [[ $name == "$want"-* ]]; then
      partial+=("$name")
    fi
  done

  # Prefer a linked runner with this exact name, then the id match, then a
  # unique prefix match. Ties break on the newest version.
  if [[ ${#by_id[@]} -eq 1 ]]; then
    printf '%s\n' "${by_id[0]}"
    return 0
  fi
  if [[ ${#by_id[@]} -gt 1 ]]; then
    printf '%s\n' "$(newest_of "${by_id[@]}")"
    return 0
  fi
  if [[ ${#partial[@]} -eq 1 ]]; then
    printf '%s\n' "${partial[0]}"
    return 0
  fi
  if [[ ${#partial[@]} -gt 1 ]]; then
    printf '%s\n' "$(newest_of "${partial[@]}")"
    return 0
  fi
  return 1
}

newest_of() {
  local n best= bestver=
  for n in "$@"; do
    local v; v=$(runner_true_version "$n")
    if [[ -z $bestver ]] || version_gt "$v" "$bestver" \
      || { [[ $v == "$bestver" ]] && [[ $n < $best ]]; }; then
      best=$n; bestver=$v
    fi
  done
  printf '%s\n' "$best"
}

declare -gA _OMACELLAR_META=()

# Reading metadata used to fork one jq per field, so a table of 12 runners cost
# ~70 processes. Load each runner's file once into an assoc array instead.
runner_meta_load() {
  local name=$1 p ck=":$name"
  [[ -n ${_OMACELLAR_META[$ck]:-} ]] && return 0
  p=$(runner_meta_path "$name")
  if [[ -f $p ]]; then
    _OMACELLAR_META[$ck]=$(jq -r 'to_entries[] | "\(.key)\t\(.value // "")"' "$p" 2>/dev/null)
  else
    # Mark it loaded-but-empty, otherwise every lookup re-runs the -f test.
    _OMACELLAR_META[$ck]=" "
  fi
  return 0
}

# Drop cached metadata for a runner, after writing or unlinking it.
runner_meta_forget() { _OMACELLAR_META[":$1"]=""; }

runner_size_label() {
  local name=$1 dir; dir=$(runner_dir_of "$name")
  if [[ -L $dir ]]; then
    printf '%s\n' "linked"
  else
    human_size "$(dir_size "$dir")"
  fi
}

# ------------------------------------------------------- steam registry ----

steam_compat_dirs() {
  local root=${STEAM_COMPAT_TOOLS_ROOT:-$XDG_DATA_HOME/Steam}
  [[ -d $root ]] || return 0
  printf '%s\n' "$root/steamapps/compatibilitytools.d" "$root/compatibilitytools.d"
}

steam_enabled() { [[ $(config_get steam_compat_tools true) != false ]]; }

runner_register_steam() {
  local name=$1 dir target
  dir=$(runner_dir_of "$name")
  [[ -d $dir ]] || return 1

  local -a dirs=()
  mapfile -t dirs < <(steam_compat_dirs | while read -r d; do [[ -d $d ]] && printf '%s\n' "$d"; done)
  if [[ ${#dirs[@]} -eq 0 ]]; then
    local root=${STEAM_COMPAT_TOOLS_ROOT:-$XDG_DATA_HOME/Steam}
    if [[ -d $root ]]; then
      mkdir -p "$root/steamapps/compatibilitytools.d" 2>/dev/null || return 1
      dirs=("$root/steamapps/compatibilitytools.d")
    else
      return 1
    fi
  fi

  local d
  for d in "${dirs[@]}"; do
    target="$d/$name"
    mkdir -p "$d"
    ln -sfn "$(readlink -f "$dir")" "$target" 2>/dev/null \
      || { log_warn "could not register $name with Steam in $d"; continue; }
    log_ok "registered with Steam ($d)"
  done
  return 0
}

runner_unregister_steam() {
  local name=$1 d
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    rm -f "$d/$name"
  done < <(steam_compat_dirs)
  return 0
}

runner_steam_label() {
  local name=$1 dir d
  dir=$(runner_dir_of "$name")
  [[ -d $dir ]] || return 0
  if [[ $(runner_meta "$name" kind) != proton ]]; then
    printf '%s\n' "n/a"
    return 0
  fi
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if [[ -e $d/$name ]]; then
      printf '%s\n' "yes"
      return 0
    fi
  done < <(steam_compat_dirs)
  printf '%s\n' "no"
}

runner_infer_id() {
  local name=$1 best= bestlen=0 id len
  registry_load
  for id in "${REG_IDS[@]}"; do
    [[ $(reg_repo "$id") == "-" || -z $(reg_repo "$id") ]] && continue
    len=${#id}
    if (( len > bestlen )) && [[ $name == "$id" || $name == "$id"-* ]]; then
      best=$id; bestlen=$len
    fi
  done
  [[ -n $best ]] || return 1
  printf '%s\n' "$best"
}

runner_detect_kind() {
  local dir=$1
  if [[ -x $dir/proton || -f $dir/proton ]]; then
    printf 'proton\n'
  elif [[ -x $dir/bin/wine || -x $dir/bin/wine64 ]]; then
    printf 'wine\n'
  else
    return 1
  fi
}

runner_probe_version() {
  local dir=$1 out= wine_bin
  for wine_bin in "$dir/bin/wine" "$dir/files/bin/wine"; do
    [[ -x $wine_bin ]] || continue
    out=$(timeout 20 "$wine_bin" --version 2>/dev/null | head -n1)
    [[ -n $out ]] && break
  done
  printf '%s\n' "$out"
}

runner_write_meta() {
  local dir=$1; shift
  local tmp; tmp=$(mktemp)
  jq -n "$@" >"$tmp" && mv -f "$tmp" "$dir/$OMACELLAR_META"
}

# Written inside the runner so it can identify itself after a rename or a move.
runner_write_version_file() {
  local dir=$1 id=$2 version=$3 kind=$4 tag=$5 probed=$6
  jq -n \
    --arg id "$id" \
    --arg version "$version" \
    --arg kind "$kind" \
    --arg tag "$tag" \
    --arg reported_version "$probed" \
    --arg arch "$(host_arch)" \
    --arg installed_at "$(date -Is)" \
    --arg manager "omacellar" \
    --arg manager_version "$OMACELLAR_VERSION" \
    '{id:$id, version:$version, kind:$kind, tag:$tag,
      reported_version:$reported_version, arch:$arch,
      installed_at:$installed_at, installed_by:$manager,
      manager_version:$manager_version}' \
    >"$dir/$OMACELLAR_VERSION_FILE"
}

# Read a runner's self-description, falling back to nothing. This is what makes
# a renamed directory still identifiable.
runner_version_file_read() {
  local dir=$1 key=$2 f="$1/$OMACELLAR_VERSION_FILE"
  [[ -f $f ]] || return 1
  jq -r --arg k "$key" '.[$k] // empty' "$f" 2>/dev/null
}

# The version a runner claims about itself: its version file first, then the
# binary, then metadata. Directory name is the last resort and can be wrong.
runner_true_version() {
  local name=$1 dir v
  dir=$(runner_dir_of "$name")
  v=$(runner_version_file_read "$dir" version 2>/dev/null)
  [[ -n $v ]] && { printf '%s\n' "$v"; return 0; }
  v=$(runner_meta "$name" version)
  [[ -n $v && $v != unknown ]] && { printf '%s\n' "$v"; return 0; }
  printf '%s\n' unknown
  return 0
}

# ------------------------------------------------------------- download ----

runner_download() {
  local url=$1 asset=$2 size=${3:-0} dest
  dest="$(downloads_dir)/$asset"
  mkdir -p "$(downloads_dir)"

  if [[ -f $dest ]] && [[ $size == 0 || $(stat -c %s "$dest") == "$size" ]]; then
    log_ok "cached $(basename "$asset") ($(human_size "$size"))"
    printf '%s\n' "$dest"
    return 0
  fi

  if [[ -f $dest ]]; then
    log_dim "  resuming partial download of $asset"
  fi

  local -a curl_args=(-fL --retry 5 --retry-delay 3 --retry-connrefused -C -)
  if [[ -t 2 ]]; then
    curl_args+=(--progress-bar)
  else
    curl_args+=(-sS)
  fi

  if ! curl "${curl_args[@]}" "$url" -o "$dest"; then
    log_err "download failed: $url"
    return 1
  fi

  local got; got=$(stat -c %s "$dest" 2>/dev/null || echo 0)
  if [[ $size != 0 && $got != "$size" ]]; then
    log_err "size mismatch for $asset (expected $size, got $got)"
    return 1
  fi
  printf '%s\n' "$dest"
}

R_ID_DISPLAY=

# /dev/tty exists on most machines even when there is no terminal behind it, so
# testing the file is not enough. Opening it is the only reliable check.
tty_can_prompt() {
  ( exec 3</dev/tty ) 2>/dev/null
}

runner_verify() {
  local file=$1 digest=$2
  [[ -z $digest || $digest == "null" ]] && {
    log_warn "upstream published no checksum for this asset, skipping verification"
    return 0
  }
  local algo=${digest%%:*}
  local want=${digest#*:}
  local tool
  case $algo in
    sha256) tool=sha256sum ;;
    sha512) tool=sha512sum ;;
    *) log_warn "unknown digest algorithm '$algo', skipping verification"; return 0 ;;
  esac
  need_cmd "$tool" "Install coreutils."
  local got; got=$("$tool" "$file" | cut -d' ' -f1)
  if [[ $got != "$want" ]]; then
    # From errortext.txt. Refusing is still the default: a checksum mismatch is
    # the one case where a stray keystroke should not install a binary. You have
    # to opt in deliberately, or pass --insecure.
    if [[ ${ALLOW_BAD_SHA:-false} == true ]]; then
      log_warn "$algo mismatch for $(basename "$file"), continuing because --insecure was given"
      log_hint "expected $algo:$want"
      log_hint "actual   $algo:$got"
      return 0
    fi

    # runner_install runs inside a command substitution, so its stdout is
    # captured. Prompts and their answers have to go through the terminal
    # directly or they never appear.
    local out=/dev/stderr

    {
      printf '\n%s%s%s\n' "$C_BOLD$C_RED" "SHA verification failed" "$C_RESET"
      printf 'SHA verification for the runner below %sFAILED%s.\n' "$C_RED" "$C_RESET"
      printf 'These types of runners can be a threat to your system.\n'
      local label=${R_ID_DISPLAY:-the downloaded runner}
      local ver=${R_VER:+ "(${R_VER})"}
      printf '%s%s%s %s%s%s%s\n' \
        "$C_CYAN" "$C_BOLD" '.' "$C_RESET" "$label" "${ver:+$C_RESET $ver}" "$C_RESET"
      printf '\n'
      printf 'expected %s:%s\n' "$algo" "$want"
      printf 'actual   %s:%s\n' "$algo" "$got"
      printf '\n'
    } >"$out"

    if tty_can_prompt; then
      printf '%s>%s(y/n) ' "$C_BOLD" "$C_RESET" >"$out"
      local reply=
      read -r reply </dev/tty || reply=
      if [[ $reply == [yY] || $reply == [yY][eE][sS] ]]; then
        log_warn "continuing with an unverified ${R_ID_DISPLAY:-runner}, on your say so"
        return 0
      fi
      printf 'aborted, nothing was installed\n' >"$out"
      return 1
    fi

    log_err "checksum mismatch for $(basename "$file") and no terminal to ask on"
    log_hint "re-run with --insecure if you trust this download"
    return 1
  fi
  log_ok "$algo verified"
}

# -------------------------------------------------------------- extract ----

runner_extract() {
  local archive=$1 dest=$2 listing tops count
  mkdir -p "$dest"

  listing=$(tar -tf "$archive" 2>/dev/null || true)
  [[ -n $listing ]] || { log_err "archive is empty or unreadable: $archive"; return 1; }

  tops=$(sed 's#^\./##; s#/.*##' <<<"$listing" | sort -u | grep -v '^$')
  count=$(wc -l <<<"$tops")

  local -a args=(-xf "$archive" -C "$dest")
  if [[ $count == 1 && $tops != "." && $tops != */* ]]; then
    args+=(--strip-components=1)
  fi

  tar "${args[@]}" || { log_err "extraction failed"; return 1; }
}

runner_verify_layout() {
  local dir=$1 kind=$2
  case $kind in
    wine)
      [[ -x $dir/bin/wine || -x $dir/bin/wine64 ]] || {
        log_err "no bin/wine in the unpacked runner"
        return 1
      }
      [[ -x $dir/bin/wineserver ]] || {
        log_warn "no bin/wineserver in this runner, launching will be slow"
      }
      ;;
    proton)
      [[ -f $dir/proton ]] || {
        log_err "no proton launcher script in the unpacked runner"
        return 1
      }
      ;;
  esac
  return 0
}

# -------------------------------------------------------------- install ----

runner_install() {
  local id=$1 version=${2:-} force=${3:-false}
  DRY_RUN=${DRY_RUN:-false}
  [[ $DRY_RUN == true ]] && force=false
  reg_exists "$id" || { log_err "unknown runner: $id"; return 1; }
  R_ID_DISPLAY=$(reg_title "$id")

  log_step "resolving $id${version:+@$version}"
  runner_resolve "$id" "$version" || return 1
  local name="$id-$R_VER"

  if runner_installed "$name" && [[ $force == false ]]; then
    log_ok "$name is already installed"
    log_hint "use --force to reinstall it"
    printf '%s\n' "$name"
    return 0
  fi

  local need=$(( ${R_SIZE:-0} * 3 ))
  local avail; avail=$(free_bytes "$(runners_dir)")
  if [[ -n $avail && $avail -gt 0 && $avail -lt $need ]]; then
    log_err "not enough free space in $(runners_dir) (need $(human_size "$need"), have $(human_size "$avail"))"
    return 1
  fi

  local kind; kind=$(reg_kind "$id")

  if [[ ${DRY_RUN:-false} == true ]]; then
    log_ok "would install $name ($kind, $(human_size "${R_SIZE:-0}"))"
    if [[ $kind == proton ]] && steam_enabled; then
      log_dim "  would register $name with Steam"
    fi
    printf '%s\n' "$name"
    return 0
  fi

  log_step "downloading $R_ASSET ($(human_size "${R_SIZE:-0}"))"
  local archive; archive=$(runner_download "$R_URL" "$R_ASSET" "${R_SIZE:-0}") || return 1
  runner_verify "$archive" "$R_DIGEST" || return 1

  log_step "unpacking"
  local newroot; newroot=$(runner_new_dir_of "$id")
  local staging="$newroot/.staging-$name-$$"
  mkdir -p "$newroot"
  safe_remove "$staging"
  mkdir -p "$staging"
  # shellcheck disable=SC2064
  trap "safe_remove '$staging'; trap - RETURN" RETURN

  runner_extract "$archive" "$staging" || return 1

  if [[ ! -x $staging/bin/wine && ! -f $staging/proton && -d $staging/*/ ]]; then
    local inner
    for inner in "$staging"/*/; do
      [[ -d $inner ]] || continue
      if [[ -x $inner/bin/wine || -f $inner/proton ]]; then
        log_dim "  unwrapping extra directory level: ${inner##*/}"
        local flat="$staging.unwrapped"
        mv "$inner" "$flat"
        safe_remove "$staging"
        mv "$flat" "$staging"
        break
      fi
    done
  fi

  kind=$(runner_detect_kind "$staging") || {
    log_err "unpacked archive does not look like a runner"
    return 1
  }
  local want_kind; want_kind=$(reg_kind "$id")
  if [[ $kind != "$want_kind" ]]; then
    log_warn "registry says $id is a '$want_kind' runner but the archive contains a '$kind' one, trusting the archive"
  fi

  runner_verify_layout "$staging" "$kind" || return 1

  local probed; probed=$(runner_probe_version "$staging")

  # A .omacellar-version file goes inside the unpacked runner so it knows what
  # it is no matter what the directory gets renamed to. Anything reading a
  # runner should prefer this over its own path.
  runner_write_version_file "$staging" "$id" "$R_VER" "$kind" "$R_TAG" "$probed"

  runner_write_meta "$staging" \
    --arg id "$id" \
    --arg version "$R_VER" \
    --arg tag "$R_TAG" \
    --arg asset "$R_ASSET" \
    --arg url "$R_URL" \
    --arg digest "${R_DIGEST:-}" \
    --arg kind "$kind" \
    --arg arch "$(host_arch)" \
    --arg installed_at "$(date -Is)" \
    --arg source "registry" \
    --arg reported_version "$probed" \
    '{id:$id, version:$version, tag:$tag, asset:$asset, url:$url, digest:$digest,
      kind:$kind, arch:$arch, installed_at:$installed_at, source:$source,
      reported_version:$reported_version}'

  # Installing a version that is already active means replacing it. Retire the
  # existing copy into Old/ rather than deleting it, unless the caller asked
  # for a clean slate.
  local target="$newroot/$R_VER"
  local active=
  local d
  for d in "$newroot"/*/; do
    [[ -d $d ]] || continue
    d=${d%/}
    [[ $d == "$target" ]] && continue
    active=${d##*/}
  done

  if [[ -e $target ]]; then
    if [[ $(config_get keep_versions) == true ]]; then
      local archived; archived="$(runner_old_dir_of "$id")/$R_VER"
      mkdir -p "$archived"
      safe_remove "$archived"
      mv "$target" "$archived"
      log_dim "  previous copy kept at ${archived#"$OMACELLAR_HOME"/}"
    else
      safe_remove "$target"
    fi
  fi

  # The version being replaced moves to Old/ so it is still launchable. This is
  # the New/Old split: exactly one version is ever active, and the outgoing one
  # is kept rather than deleted.
  if [[ -n $active ]]; then
    local archived; archived="$(runner_old_dir_of "$id")/$active"
    if [[ -e $archived ]]; then
      log_dim "  $active was already in Old/, replacing that copy"
      safe_remove "$archived"
    fi
    mkdir -p "$(dirname "$archived")"
    mv "$newroot/$active" "$archived" \
      && log_dim "  retired $active to ${archived#"$OMACELLAR_HOME"/}"
  fi

  if ! mv "$staging" "$target"; then
    log_err "could not move the new runner into place"
    return 1
  fi
  runner_index_build
  runner_meta_forget "$name"

  log_ok "installed $name${probed:+ ($probed)}"

  if [[ $kind == proton ]] && steam_enabled; then
    runner_register_steam "$name" || log_dim "  (Steam not found, skipping compatibility tool registration)"
  fi

  printf '%s\n' "$name"
}

# ------------------------------------------------------------- remove ----

runner_uninstall() {
  local name=$1 assume_yes=${2:-false}
  local dir; dir=$(runner_dir_of "$name")
  [[ -e $dir ]] || { log_err "no such runner: $name"; return 1; }

  # Refuse to pull a runner out from under a prefix that still points at it.
  # For a linked runner this means "unlink", which orphans the same bottles.
  local p
  while IFS= read -r p; do
    if [[ $(prefix_meta "$p" runner) == "$name" ]]; then
      log_err "$p was built with $name and will not run without it"
      log_hint "recreate it against another runner first: omacellar prefix remove $p --yes"
      return 1
    fi
  done < <(prefix_list)

  local linked; linked=$(runner_meta "$name" source)
  if [[ $linked == local ]]; then
    if [[ $assume_yes != true ]]; then
      log_warn "$name is a linked runner, its files live outside omacellar"
      log_hint "use 'omacellar runner unlink $name' to just forget it"
      confirm "Remove the link?" || return 1
    fi
    runner_unregister_steam "$name"
    rm -f "$(runner_meta_path "$name")"
    rm -f "$dir"
    runner_meta_forget "$name"
    runner_index_build
    log_ok "unlinked $name"
    return 0
  fi

  log_dim "  $name occupies $(human_size "$(dir_size "$dir")")"

  if [[ $assume_yes != true ]]; then
    confirm "Remove $name?" || { log_dim "kept $name"; return 0; }
  fi

  runner_unregister_steam "$name"
  safe_remove "$dir"
  runner_meta_forget "$name"
  runner_index_build
  # An empty <id>/ left behind is just clutter.
  local idroot; idroot="$(runner_new_dir_of "$(runner_id_of "$name")")"
  [[ -d $idroot && -z $(ls -A "$idroot" 2>/dev/null) ]] && safe_remove "$(dirname "$idroot")"
  log_ok "removed $name"

  if [[ $(config_get default_runner) == "$name" ]]; then
    local next; next=$(prefix_newest_installed_runner 2>/dev/null || true)
    [[ -n $next ]] && config_set default_runner "$next"
    log_hint "default_runner is now '${next:-unset}'"
  fi
}

# --------------------------------------------------------------- link ----

runner_link() {
  local src=$1 name=${2:-}
  src=${src/#\~/$HOME}
  dir_exists "$src" || { log_err "not a directory: $src"; return 1; }
  src=$(cd "$src" && pwd)

  local kind; kind=$(runner_detect_kind "$src") || {
    log_err "$src has neither bin/wine nor a proton script"
    return 1
  }

  local id
  if [[ -z $name ]]; then
    id=$(runner_infer_id "${src##*/}") || {
      log_err "cannot tell which runner this is; pass --as <id> (try: $(cut -d'|' -f1 "$OMACELLAR_REGISTRY_FILE" | grep -v '^#' | tr '\n' ' '))"
      return 1
    }
  else
    reg_exists "$name" || { log_err "unknown runner id: $name"; return 1; }
    id=$name
  fi

  local base; base=$(sanitize_name "${src##*/}")
  if [[ -z $name ]]; then
    if [[ $base == "$id" || $base == "$id"-* ]]; then
      name=$base
    else
      name="$id-$base"
    fi
  fi

  # Linked runners stay a symlink directly in runners/, keyed by their own name.
# They were never unpacked by us so they get no New/Old treatment.
local dest; dest="$(runners_dir)/$name"
  mkdir -p "$(runners_dir)/$OMACELLAR_META_DIR"
  if [[ -e $dest || -L $dest ]]; then
    log_err "$name already exists, choose another name"
    return 1
  fi
  ln -s "$src" "$dest"
  runner_index_build

  local probed; probed=$(runner_probe_version "$src")
  local ver=${probed#wine-}
  [[ -z $ver ]] && ver=unknown

  jq -n --arg id "$id" --arg version "$ver" --arg kind "$kind" \
    --arg arch "$(host_arch)" --arg installed_at "$(date -Is)" \
    --arg path "$src" --arg reported_version "$probed" \
    '{id:$id, version:$version, tag:"", asset:"", url:"", digest:"",
      kind:$kind, arch:$arch, installed_at:$installed_at, source:"local",
      path:$path, reported_version:$reported_version}' \
    >"$(runner_meta_path "$name")"

  log_ok "linked $name -> $src${probed:+ ($probed)}"
  printf '%s\n' "$name"
}

runner_unlink() {
  local name=$1
  local dir; dir=$(runner_dir_of "$name")
  [[ -L $dir ]] || { log_err "$name is not a linked runner"; return 1; }
  rm -f "$(runner_meta_path "$name")"
  rm -f "$dir"
  runner_meta_forget "$name"
  runner_index_build
  log_ok "unlinked $name"
}

# --------------------------------------------------------------- adopt ----

runner_adopt() {
  local dir name id adopted=0 skipped=0
  while IFS= read -r name; do
    dir=$(runner_dir_of "$name")
    [[ -L $dir ]] && continue
    if [[ -f $dir/$OMACELLAR_META ]]; then
      skipped=$(( skipped + 1 ))
      continue
    fi
    if runner_detect_kind "$dir" >/dev/null 2>&1 && id=$(runner_infer_id "$name"); then
      local kind; kind=$(runner_detect_kind "$dir")
      local probed; probed=$(runner_probe_version "$dir")
      # Built with jq, not string concatenation: a probed version containing a
      # quote would otherwise produce invalid JSON.
      jq -n --arg id "$id" --arg kind "$kind" --arg reported_version "$probed" \
        --arg arch "$(host_arch)" --arg installed_at "$(date -Is)" \
        '{id:$id, version:"unknown", tag:"", asset:"", url:"", digest:"",
          kind:$kind, arch:$arch, installed_at:$installed_at, source:"adopted",
          reported_version:$reported_version}' \
        >"$dir/$OMACELLAR_META"
      runner_write_version_file "$dir" "$id" unknown "$kind" "" "$probed"
      log_ok "adopted $name as $id${probed:+ ($probed)}"
      adopted=$(( adopted + 1 ))
      continue
    fi
    log_warn "skipping $name, does not look like a runner"
  done < <(runner_list_installed)

  log_dim "adopted $adopted, already known $skipped"
  [[ $adopted -eq 0 && $skipped -eq 0 ]] && return 1
  return 0
}