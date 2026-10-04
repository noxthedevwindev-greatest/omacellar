#!/usr/bin/env bash
# omacellar :: updates
# Compares what is installed against what upstream published.

[[ -n "${_OMACELLAR_UPDATE:-}" ]] && return 0
_OMACELLAR_UPDATE=1

runner_update_status() {
  local name=$1 id installed latest
  id=$(runner_meta "$name" id)
  [[ -z $id ]] && id=$(runner_infer_id "$name" 2>/dev/null) || true

  local source; source=$(runner_meta "$name" source)
  case $source in
    local)
      printf 'local\t%s\t-\t%s\n' "$(runner_true_version "$name")" "${id:-?}"
      return 0
      ;;
    adopted)
      printf 'unmanaged\t%s\t-\t%s\n' "$(runner_true_version "$name")" "${id:-?}"
      return 0
      ;;
  esac

  [[ -n $id ]] || { printf 'unmanaged\t-\t-\t?\n'; return 0; }
  reg_exists "$id" || { printf 'unmanaged\t%s\t-\t%s\n' "$(runner_true_version "$name")" "$id"; return 0; }

  # Trust the version file inside the runner over the directory name, which
  # says nothing once a runner has been renamed or moved.
  installed=$(runner_true_version "$name")
  latest=$(runner_latest_version "$id" 2>/dev/null | cut -f1)
  [[ -n $latest ]] || { printf 'unmanaged\t%s\t-\t%s\n' "$installed" "$id"; return 0; }

  local status=current
  [[ $installed == unknown ]] && status=unmanaged
  [[ $installed != unknown ]] && version_gt "$latest" "$installed" && status=outdated

  printf '%s\t%s\t%s\t%s\n' "$status" "$installed" "$latest" "$id"
}

runner_update() {
  local target=$1 check=${2:-false} assume_yes=${3:-false}
  local -a names=()

  if [[ $target == --all ]]; then
    mapfile -t names < <(runner_list_installed)
    [[ ${#names[@]} -gt 0 ]] || { log_warn "no runners installed"; return 0; }
  else
    names=("$target")
  fi

  local name status installed latest id changed=0

  for name in "${names[@]}"; do
    [[ -d $(runner_dir_of "$name") ]] || { log_err "no such runner: $name"; continue; }

    IFS=$'\t' read -r status installed latest id <<<"$(runner_update_status "$name")"

    case $status in
      local)
        log_dim "  $name is linked, nothing to update"
        continue
        ;;
      unmanaged)
        log_dim "  $name is not tracked upstream ($id), skipping"
        log_hint "adopt or reinstall it to get updates: omacellar runner adopt"
        continue
        ;;
      current)
        printf '%s%-28s%s %s\n' "$C_DIM" "$name" "$C_RESET" "up to date ($installed)"
        continue
        ;;
      outdated) ;;
    esac

    changed=1
    printf '%s%-28s%s %s -> %s\n' "$C_YELLOW" "$name" "$C_RESET" "$installed" "$latest"

    if [[ $check == true ]]; then
      continue
    fi
    if [[ $assume_yes != true ]]; then
      confirm "  update $name to $latest?" || { log_dim "    skipped"; continue; }
    fi

    # The active version directory gets replaced and the outgoing one is
    # archived into Old/ inside runner_install, so keep_versions decides
    # whether it survives.
    if with_lock runner_install "$id" "$latest" --force >/dev/null; then
      local newname="$id-$latest"
      local olddir; olddir=$(runner_dir_of "$name")

      # Bottles point at a runner by name. Re-point the ones that used the old
      # version, or they will look for a directory that no longer exists.
      local p repointed=0
      while IFS= read -r p; do
        [[ $(prefix_meta "$p" runner) == "$name" ]] || continue
        local m; m=$(prefix_meta_path "$p")
        local tmp; tmp=$(mktemp)
        if jq --arg r "$newname" '.runner = $r' "$m" >"$tmp" 2>/dev/null; then
          mv -f "$tmp" "$m"
          repointed=$(( repointed + 1 ))
        else
          rm -f "$tmp"
        fi
      done < <(prefix_list)
      (( repointed > 0 )) && log_dim "    re-pointed $repointed prefix(es) at $newname"

      # The old name no longer resolves unless the same version was reinstalled.
      runner_index_build
      if [[ ! -e $(runner_dir_of "$name") ]]; then
        runner_meta_forget "$name"
        # Its Steam registration pointed at the old directory.
        [[ $(runner_meta "$newname" kind) == proton ]] && runner_register_steam "$newname" >/dev/null 2>&1
      fi

      # runner_install already moved the outgoing version into Old/, which is
      # the behaviour keep_versions=true describes. When it is false, drop that
      # archived copy so the cellar does not grow without bound.
      if [[ $(config_get keep_versions) != true ]]; then
        local archived; archived="$(runner_old_dir_of "$id")/$installed"
        if [[ -d $archived ]]; then
          safe_remove "$archived"
          log_dim "    dropped the old $installed copy (set keep_versions=true to keep it)"
        fi
      else
        log_dim "    kept the old $installed copy in Old/"
      fi

      log_ok "$name -> $newname"
    else
      log_err "update of $name failed, leaving the old one in place"
    fi
  done

  [[ $changed -eq 0 ]] && log_dim "everything is current"
  return 0
}

runner_update_available() {
  local name status installed latest id
  while IFS= read -r name; do
    IFS=$'\t' read -r status installed latest id <<<"$(runner_update_status "$name")"
    [[ $status == outdated ]] && printf '%s\t%s\t%s\n' "$name" "$installed" "$latest"
  done < <(runner_list_installed)
}