#!/usr/bin/env bash
# omacellar :: output formatting
#
# Rows are appended with ui_row and rendered with ui_table. Cells may contain
# ANSI colour: widths are measured on the text with escapes stripped.

[[ -n "${_OMACELLAR_UI:-}" ]] && return 0
_OMACELLAR_UI=1

declare -ga UI_CELLS=()
UI_COLS=0

ui_dim() { printf '%s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }

ui_reset() { UI_CELLS=(); UI_COLS=0; }

ui_row() {
  [[ $# -gt $UI_COLS ]] && UI_COLS=$#
  UI_CELLS+=("$@")
}

ui_strip_ansi() {
  local s=$1
  [[ $s == *$'\033'* ]] || { printf '%s' "$s"; return; }
  printf '%s' "$s" | sed $'s/\033\\[[0-9;]*m//g'
}

ui_table() {
  [[ $UI_COLS -gt 0 ]] || return 0

  local -a widths=()
  local i c w
  for ((i = 0; i < ${#UI_CELLS[@]}; i += UI_COLS)); do
    for ((c = 0; c < UI_COLS; c++)); do
      w=$(ui_width "${UI_CELLS[i + c]:-}")
      [[ ${widths[c]:-0} -lt $w ]] && widths[c]=$w
    done
  done

  local out pad
  for ((i = 0; i < ${#UI_CELLS[@]}; i += UI_COLS)); do
    out=
    for ((c = 0; c < UI_COLS; c++)); do
      local cell=${UI_CELLS[i + c]:-}
      w=$(ui_width "$cell")
      pad=$(( ${widths[c]} - w ))
      (( pad < 0 )) && pad=0
      out+="$cell"
      (( c + 1 < UI_COLS )) && out+=$(printf "%$(( pad + 2 ))s" '')
    done
    printf '%s\n' "$out"
  done
  return 0
}

ui_width() {
  local s=${1:-}
  [[ $s == *$'\033'* ]] && s=$(ui_strip_ansi "$s")
  # Character count, not byte count: the tables hold accented registry titles.
  local LC_ALL=${LC_ALL:-C.UTF-8}
  export LC_ALL
  # shellcheck disable=SC2002
  printf '%s' "$s" | wc -m | tr -d ' '
}

# -------------------------------------------------------------- json ----

# Thin wrapper so every --json path emits valid output the same way. Keys go
# out in argument order, values are emitted raw, so callers pass pre-quoted
# JSON (use json_str for anything from outside).
json_str() {
  printf '%s' "$1" | jq -Rsa .
}

json_emit() {
  local -a keys=() vals=()
  while (( $# >= 2 )); do
    keys+=("$1")
    vals+=("$2")
    shift 2
  done

  local out='{' i last=$((${#keys[@]} - 1))
  for ((i = 0; i < ${#keys[@]}; i++)); do
    out+="$(json_str "${keys[i]}"):${vals[i]}"
    (( i < last )) && out+=','
  done
  printf '%s\n' "${out}}"
}

json_array() {
  printf '['
  local i first=1
  for i in "$@"; do
    (( first )) || printf ','
    printf '%s' "$i"
    first=0
  done
  printf ']\n'
}

json_bool() {
  case $1 in
    true | yes | 1) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

ui_kv() {
  local -a pairs=("$@")
  [[ ${#pairs[@]} -eq 0 ]] && return 0
  local width=0 i
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    (( ${#pairs[i]} > width )) && width=${#pairs[i]}
  done
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    printf '  %-*s  %s\n' "$width" "${pairs[i]}" "${pairs[i + 1]}"
  done
}

ui_paint() {
  local word=$1
  case $word in
    ok | installed | current | win32+win64 | win64 | both) printf '%s%s%s\n' "$C_GREEN" "$word" "$C_RESET" ;;
    outdated | update | experimental | variant | unknown | unmanaged | missing | partial) printf '%s%s%s\n' "$C_YELLOW" "$word" "$C_RESET" ;;
    broken | failed | error) printf '%s%s%s\n' "$C_RED" "$word" "$C_RESET" ;;
    *) printf '%s\n' "$word" ;;
  esac
}