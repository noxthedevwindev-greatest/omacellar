#!/usr/bin/env bash
#
# omacellar uninstaller
#
#   sudo ./uninstall.sh            remove the program, ask about the cellar
#   sudo ./uninstall.sh --purge    remove the program and ~/.omacellar
#   sudo ./uninstall.sh --keep-data  remove the program, keep ~/.omacellar
#
# Running without sudo removes what you can and reports what you cannot,
# rather than stopping at the first permission error. Re-run with sudo for the
# rest. You do not need root if everything is under your own PREFIX.
#
# --yes skips the questions, --purge never asks about the cellar.
# CELLS and PREFIX are honoured if you installed somewhere unusual.
#
# Undoes install.sh. Anything it is not certain about, it says so and stops.

set -euo pipefail

PREFIX=${PREFIX:-/usr}
CELLS=${CELLS:-$HOME/.omacellar}

PURGE=false
KEEP_CELLAR=false
ASSUME_YES=${OMACELLAR_ASSUME_YES:-false}
for arg in "$@"; do
  case $arg in
    # Last one wins, so --keep-data after --purge really keeps the cellar.
    --purge | --all) PURGE=true; KEEP_CELLAR=false ;;
    --keep-data | --keep-cellar) PURGE=false; KEEP_CELLAR=true ;;
    --yes | -y) ASSUME_YES=true ;;
    -h | --help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      printf '\n'
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n\n' "$arg" >&2
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
      exit 1
      ;;
  esac
done

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; OFF=$'\033[0m'
[[ -t 1 ]] || { BOLD=; DIM=; RED=; GREEN=; YELLOW=; CYAN=; OFF=; }

say()  { printf '%s\n' "$*"; }

# A PREFIX of / turns every path below into a top-level system path. Catch it
# before anything is deleted rather than after.
case $PREFIX in
  "" | "/" | "//")
    printf 'refusing to run with PREFIX=%s\n' "'$PREFIX'" >&2
    printf 'PREFIX is where install.sh put things, usually /usr or /usr/local\n' >&2
    exit 1
    ;;
esac

step() { printf '%s==>%s %s\n' "$CYAN$BOLD" "$OFF" "$*"; }
ok()   { printf '%s  removed%s %s\n' "$GREEN" "$OFF" "$*"; }
skip() { printf '%s  absent%s  %s\n' "$DIM" "$OFF" "$*"; }
die()  { printf 'err %s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

# When this runs as `curl ... | sudo bash`, stdin is the pipe carrying the
# script, so it cannot also carry the answer. Go to the terminal directly, and
# treat a machine with no terminal as a no rather than a guess.
tty_can_prompt() {
  ( exec 3</dev/tty ) 2>/dev/null
}

confirm() {
  [[ $ASSUME_YES == true ]] && return 0
  tty_can_prompt || return 1
  local reply
  printf '%s [y/N] ' "$1" >/dev/tty
  read -r reply </dev/tty || reply=
  [[ $reply == [yY] || $reply == [yY][eE][sS] ]]
}

# Refuse to remove anything that is not plausibly ours. An empty or root-ish
# path here would be a very bad afternoon.
#
# The cellar path is whatever the user configured, so it is trusted by
# position rather than by name. Everything else is a fixed location under
# PREFIX, so it has to look like ours.
safe_rm_cellar() {
  local target=$1
  case $target in
    "" | "/" | "$HOME" | "/home" | "/usr" | "/etc" | "/var")
      die "refusing to remove the cellar at $target"
      ;;
  esac
  rm -rf -- "$target"
}

safe_rm() {
  local target=$1
  case $target in
    "" | "/" | "//" | "$HOME" | "/home" | "/usr" | "/etc" | "/var" | "/usr/bin" | "/usr/share")
      die "refusing to remove $target"
      ;;
  esac
  [[ $target == *"/omacellar"* || $target == *"/_omacellar" || $target == *"/omacellar."* ]] \
    || die "refusing to remove $target, it does not look like an omacellar path"
  rm -rf -- "$target"
}

human_size() {
  local b=${1:-0}
  awk -v b="$b" 'BEGIN{
    split("B KiB MiB GiB TiB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

dir_size() {
  local d=$1
  [[ -e $d ]] || { printf '0\n'; return 0; }
  du -sb "$d" 2>/dev/null | cut -f1 || printf '0\n'
}

printf '\n%somacellar uninstall%s  %s(%s)%s\n\n' \
  "$BOLD" "$OFF" "$DIM" "$PREFIX" "$OFF"

# ----------------------------------------------------------------- cellar ----

# The cellar and the program files are independent: you can have one without
# the other, so neither is allowed to short-circuit the other.
cellar_removed=true
step "cellar"
if [[ ! -e $CELLS ]]; then
  skip "$CELLS"
  cellar_removed=false
else
  cellar_size=$(human_size "$(dir_size "$CELLS")")

  printf '\n%sThe cellar holds%s\n' "$BOLD" "$OFF"
  printf '  %s\n' "$CELLS"
  printf '  %s\n\n' "$cellar_size"

  if [[ $PURGE == true ]]; then
    printf '%sEvery runner and prefix in it goes too.%s\n\n' "$DIM" "$OFF"
  elif [[ $KEEP_CELLAR == true ]]; then
    printf '%sKeeping it, since you asked.%s\n\n' "$DIM" "$OFF"
  else
    printf 'Remove it, along with every runner and prefix inside?\n'
  fi

  cellar_removed=false
  if [[ $PURGE == true ]] || confirm "  go ahead?"; then
    safe_rm_cellar "$CELLS"
    cellar_removed=true
    printf '\n  %sremoved%s %s\n\n' "$GREEN" "$OFF" "$CELLS"
  else
    printf '\n  %skept%s    %s\n\n' "$DIM" "$OFF" "$CELLS"
    say '  Nothing in the cellar was touched. To delete it without being asked'
    say '  next time, run with --purge.'
  fi
fi

# ------------------------------------------------------------------ files ----

step "program files"
installed_any=false
denied=()
for f in \
  "$PREFIX/bin/omacellar" \
  "$PREFIX/share/omacellar" \
  "$PREFIX/share/bash-completion/completions/omacellar" \
  "$PREFIX/share/zsh/site-functions/_omacellar" \
  "$PREFIX/share/fish/vendor_completions.d/omacellar.fish" \
  "$PREFIX/share/doc/omacellar" \
  "$PREFIX/share/licenses/omacellar"; do
  if [[ -e $f || -L $f ]]; then
    # A permission error is expected when not running as root. Carry on and
    # list the leftovers at the end instead of dying on the first one.
    if safe_rm "$f" 2>/dev/null; then
      ok "$f"
      installed_any=true
    else
      denied+=("$f")
    fi
  else
    skip "$f"
  fi
done

if [[ $installed_any == false && ${#denied[@]} -eq 0 ]]; then
  printf '\n%snothing was installed under %s%s\n' "$DIM" "$PREFIX" "$OFF"
fi

if [[ $cellar_removed == false ]]; then
  printf '\n%skept%s   %s\n' "$DIM" "$OFF" "$CELLS"
  say ''
  say '  Your runners and prefixes are still there. Put the program back with'
  say '  ./install.sh and they will be waiting.'
fi

if [[ ${#denied[@]} -gt 0 ]]; then
  printf '\n%s%d path(s) need root%s\n' "$YELLOW" "${#denied[@]}" "$OFF"
  printf '  %s\n' "${denied[@]}"
  printf '\n  Re-run with sudo to finish:\n    sudo %q\n' "./uninstall.sh"
fi

printf '\n%somacellar uninstalled%s\n' "$BOLD" "$OFF"

# Remind about the places state can linger outside the cellar.
leftovers=()
[[ -e ${XDG_CONFIG_HOME:-$HOME/.config}/omacellar ]] && leftovers+=("${XDG_CONFIG_HOME:-$HOME/.config}/omacellar")
[[ -e ${XDG_DATA_HOME:-$HOME/.local/share}/omacellar ]] && leftovers+=("${XDG_DATA_HOME:-$HOME/.local/share}/omacellar")
[[ -e ${XDG_CACHE_HOME:-$HOME/.cache}/omacellar ]] && leftovers+=("${XDG_CACHE_HOME:-$HOME/.cache}/omacellar")

if [[ ${#leftovers[@]} -gt 0 ]]; then
  say ''
  say "${#leftovers[@]} older location(s) were left behind:"
  printf '  %s\n' "${leftovers[@]}"
  say ''
  say 'They belong to layouts omacellar no longer uses. Remove them with:'
  printf '  rm -rf %s\n' "${leftovers[*]}"
fi

say ''
say 'Restart your shell to drop any cached completion.'
printf '\n'