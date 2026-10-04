#!/usr/bin/env bash
#
# omacellar installer
#
#   curl -fsSL https://raw.githubusercontent.com/noxthedevwindev-greatest/omacellar/main/install.sh | sudo bash
#
# Installs the binary, its libraries and shell completions. Touches nothing in
# your home directory: the cellar at ~/.omacellar is created on first run.

set -euo pipefail

REPO=noxthedevwindev-greatest/omacellar
REF=main
PREFIX=${PREFIX:-/usr}
REPO_URL=https://github.com/$REPO

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; CYAN=$'\033[36m'; OFF=$'\033[0m'
[[ -t 1 ]] || { BOLD=; DIM=; RED=; CYAN=; OFF=; }

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$CYAN$BOLD" "$OFF" "$*"; }
die()  { printf 'err %s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

step "fetching $REPO@$REF"
curl -fsSL "$REPO_URL/archive/refs/heads/$REF.tar.gz" -o "$tmp/src.tar.gz" \
  || die "could not download $REPO_URL/archive/refs/heads/$REF.tar.gz"
tar -xzf "$tmp/src.tar.gz" -C "$tmp"
src=$(find "$tmp" -maxdepth 1 -type d -name "$REPO-*" | head -n1)
[[ -n $src ]] || die "the archive did not contain $REPO"
[[ -f $src/bin/omacellar ]] || die "no bin/omacellar in the archive"

step "installing to $PREFIX"
install -Dm755 "$src/bin/omacellar" "$PREFIX/bin/omacellar"
install -d "$PREFIX/share/omacellar/lib" "$PREFIX/share/omacellar/registry"
install -m644 "$src"/lib/*.sh "$PREFIX/share/omacellar/lib/"
install -m644 "$src/registry/runners.conf" "$PREFIX/share/omacellar/registry/runners.conf"
install -Dm644 "$src/LICENSE" "$PREFIX/share/licenses/omacellar/LICENSE"
install -Dm644 "$src/README.md" "$PREFIX/share/doc/omacellar/README.md"

step "shell completions"
found=false
if [[ -d $PREFIX/share/bash-completion/completions ]]; then
  install -Dm644 "$src/completions/omacellar.bash" \
    "$PREFIX/share/bash-completion/completions/omacellar"
  found=true
fi
if [[ -d $PREFIX/share/zsh/site-functions ]]; then
  install -Dm644 "$src/completions/_omacellar" \
    "$PREFIX/share/zsh/site-functions/_omacellar"
  found=true
fi
if [[ -d $PREFIX/share/fish/vendor_completions.d ]]; then
  install -Dm644 "$src/completions/omacellar.fish" \
    "$PREFIX/share/fish/vendor_completions.d/omacellar.fish"
  found=true
fi
[[ $found == true ]] || printf '%s  (no completion directory found, skipped)%s\n' "$DIM" "$OFF"

printf '\n%somacellar installed%s\n\n' "$BOLD" "$OFF"
say "  omacellar runner list         what is in the cellar, what is upstream"
say "  omacellar runner add soda     install a runner"
say "  omacellar prefix create games make an installation"
say "  omacellar doctor              check the machine"
say "  omacellar about               credits"
printf '\n%sEverything it installs lives in ~/.omacellar, not in ~/.local/share.%s\n' "$DIM" "$OFF"
printf '%sNew shells pick up the completions. Restart yours if completion is missing.%s\n\n' "$DIM" "$OFF"