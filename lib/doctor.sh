#!/usr/bin/env bash
# omacellar :: doctor
# Everything that can be wrong before a launch goes wrong.

[[ -n "${_OMACELLAR_DOCTOR:-}" ]] && return 0
_OMACELLAR_DOCTOR=1

declare -g DOCTOR_FAILURES=0
declare -g DOCTOR_WARNINGS=0

doc_pass() { printf '  %sok%s    %s\n' "$C_GREEN" "$C_RESET" "$1"; }
doc_fail() {
  printf '  %sfail%s  %s\n' "$C_RED" "$C_RESET" "$1"
  [[ -n ${2:-} ]] && printf '        %s%s%s\n' "$C_DIM" "$2" "$C_RESET"
  DOCTOR_FAILURES=$(( DOCTOR_FAILURES + 1 ))
  return 0
}
doc_warn() {
  printf '  %swarn%s  %s\n' "$C_YELLOW" "$C_RESET" "$1"
  [[ -n ${2:-} ]] && printf '        %s%s%s\n' "$C_DIM" "$2" "$C_RESET"
  DOCTOR_WARNINGS=$(( DOCTOR_WARNINGS + 1 ))
  return 0
}

doctor_tools() {
  printf '\n%sdependencies%s\n' "$C_BOLD" "$C_RESET"

  local c
  for c in bash curl jq tar gzip xz; do
    command -v "$c" >/dev/null 2>&1 \
      && doc_pass "$c" \
      || doc_fail "$c not found" "required by omacellar"
  done

  # Not fatal, but without it two installs can race on the same staging path.
  command -v flock >/dev/null 2>&1 \
    && doc_pass "flock" \
    || doc_warn "flock missing" "installs will not be serialised"

  if command -v xz >/dev/null 2>&1; then
    doc_pass "xz decompression (soda, caffe, wine-ge tarballs)"
  fi

  command -v zstd >/dev/null 2>&1 \
    && doc_pass "zstd decompression" \
    || doc_warn "zstd missing" "only needed for .tar.zst runners"

  command -v winetricks >/dev/null 2>&1 \
    && doc_pass "winetricks" \
    || doc_warn "winetricks missing" "omacellar prefix winetricks needs it"

  command -v git >/dev/null 2>&1 \
    && doc_pass "git" \
    || doc_warn "git missing" "only needed for custom runner builds"
}

doctor_paths() {
  printf '\n%sstorage%s\n' "$C_BOLD" "$C_RESET"

  local dir
  for dir in "$(runners_dir)" "$(prefixes_dir)"; do
    if mkdir -p "$dir" 2>/dev/null && [[ -w $dir ]]; then
      doc_pass "$dir ($(human_size "$(dir_size "$dir")"))"
    else
      doc_fail "cannot write to $dir" "check permissions or OMACELLAR_HOME"
    fi
  done

  local avail need
  avail=$(free_bytes "$(runners_dir)")
  if [[ -n $avail ]]; then
    if (( avail < 2 * 1024 * 1024 * 1024 )); then
      doc_warn "only $(human_size "$avail") free in $(runners_dir)" \
        "a runner plus a Proton build needs about 2G"
    else
      doc_pass "$(human_size "$avail") free for runners"
    fi
  fi
  unset need
}

doctor_env() {
  printf '\n%senvironment%s\n' "$C_BOLD" "$C_RESET"

  if [[ -n ${WINEPREFIX:-} ]]; then
    doc_warn "WINEPREFIX is set in your shell" \
      "prefix: $WINEPREFIX (omacellar clears this for every launch)"
  else
    doc_pass "WINEPREFIX is not set"
  fi

  if [[ -n ${WINESERVER:-}${WINELOADER:-}${WINE:-} ]]; then
    doc_warn "WINESERVER/WINELOADER/WINE point somewhere" \
      "WINE=${WINE:-unset} WINELOADER=${WINELOADER:-unset} WINESERVER=${WINESERVER:-unset}"
  else
    doc_pass "no runner variables leaked into your shell"
  fi

  if [[ -n ${GITHUB_TOKEN:-}${GH_TOKEN:-} ]]; then
    doc_pass "a GitHub token is set (higher API rate limit)"
  else
    doc_warn "no GITHUB_TOKEN" \
      "unauthenticated GitHub API calls are limited to 60 per hour"
  fi
}

doctor_runners() {
  printf '\n%scellar%s\n' "$C_BOLD" "$C_RESET"

  local -a names=()
  mapfile -t names < <(runner_list_installed)
  if [[ ${#names[@]} -eq 0 ]]; then
    doc_warn "no runners installed" "omacellar runner add soda"
    return 0
  fi

  local name kind dir reported
  for name in "${names[@]}"; do
    dir=$(runner_dir_of "$name")
    if kind=$(runner_detect_kind "$dir"); then
      reported=$(runner_meta "$name" reported_version)
      local extra=
      if [[ $kind == wine ]]; then
        if runner_has_win32 "$name"; then
          extra=", can make win32 prefixes"
        else
          extra=", WoW64 (one win64 prefix runs both bitnesses)"
        fi
      fi
      doc_pass "$name  ($kind${reported:+, $reported}$extra)"
    else
      doc_fail "$name is broken" "no bin/wine and no proton script in $dir"
    fi
  done
}

doctor_prefixes() {
  printf '\n%sinstallations%s\n' "$C_BOLD" "$C_RESET"

  local -a names=()
  mapfile -t names < <(prefix_list)
  if [[ ${#names[@]} -eq 0 ]]; then
    doc_warn "no installations yet" "omacellar prefix create default --runner soda"
    return 0
  fi

  local name runner bitness
  for name in "${names[@]}"; do
    if ! prefix_exists "$name"; then
      doc_fail "$name is not a valid prefix" "no drive_c/system.reg, recreate it"
      continue
    fi
    runner=$(prefix_meta "$name" runner)
    bitness=$(prefix_meta "$name" bitness unknown)
    if [[ -n $runner ]] && [[ ! -e $(runner_dir_of "$runner") ]]; then
      doc_fail "$name points at missing runner '$runner'" \
        "reinstall $runner or recreate the installation"
      continue
    fi
    doc_pass "$name  ($bitness, $runner, $(human_size "$(dir_size "$(prefix_path "$name")")"))"

    # Anything prefix_problems can see, surfaced here as well, so doctor and
    # prefix run agree about what is wrong.
    local problem
    while IFS= read -r problem; do
      [[ -n $problem ]] || continue
      if problem_is_fixable "$problem"; then
        doc_warn "$name: $(problem_message "$problem")" \
          "prefix run will offer to fix it"
      else
        doc_warn "$name: $(problem_message "$problem")"
      fi
    done < <(prefix_problems "$name")
  done
}

doctor_display() {
  printf '\n%sgraphics%s\n' "$C_BOLD" "$C_RESET"

  if command -v vulkaninfo >/dev/null 2>&1; then
    local icd
    icd=$(ls /usr/share/vulkan/icd.d/*.json 2>/dev/null | head -n3 | xargs -r -n1 basename | tr '\n' ' ')
    [[ -n $icd ]] && doc_pass "vulkan ICDs: $icd" \
      || doc_warn "no Vulkan ICD installed" "Windows games will fall back to OpenGL"
  else
    doc_warn "vulkaninfo not installed" "install vulkan-tools to check DXVK/VKD3D readiness"
  fi

  if [[ -n ${__GLX_VENDOR_LIBRARY_NAME:-} ]]; then
    doc_warn "__GLX_VENDOR_LIBRARY_NAME=$__GLX_VENDOR_LIBRARY_NAME is set" \
      "harmless without an NVIDIA driver, breaks GL if one is half installed"
  fi
}

doctor_run() {
  DOCTOR_FAILURES=0
  DOCTOR_WARNINGS=0

  printf '%somacellar doctor%s  %s(%s)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$OMACELLAR_VERSION" "$C_RESET"
  printf '%shome: %s%s\n' "$C_DIM" "$OMACELLAR_HOME" "$C_RESET"

  doctor_tools
  doctor_paths
  doctor_env
  doctor_runners
  doctor_prefixes
  doctor_display

  printf '\n'
  if (( DOCTOR_FAILURES > 0 )); then
    printf '%s%d problem(s), %d warning(s)%s\n' "$C_RED" "$DOCTOR_FAILURES" "$DOCTOR_WARNINGS" "$C_RESET"
    return 1
  elif (( DOCTOR_WARNINGS > 0 )); then
    printf '%sno problems, %d warning(s)%s\n' "$C_YELLOW" "$DOCTOR_WARNINGS" "$C_RESET"
    return 0
  fi
  printf '%sall good%s\n' "$C_GREEN" "$C_RESET"
}