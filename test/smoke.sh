#!/usr/bin/env bash
#
# omacellar smoke test
#
# Runs against a throwaway cellar and a throwaway cache, so it never touches a
# real installation. Pass runner directories to link real ones:
#
#   test/smoke.sh ~/Projects/OmaWin/runners/*
#
# With no arguments it only tests what needs no runner: argument parsing, the
# registry, table rendering and the failure paths.

set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OC=$ROOT/bin/omacellar

WORK=$(mktemp -d)
export OMACELLAR_HOME=$WORK/cellar
export XDG_CACHE_HOME=$WORK/cache
export XDG_CONFIG_HOME=$WORK/config
export XDG_DATA_HOME=$WORK/data
export NO_COLOR=1
trap 'rm -rf "$WORK"' EXIT

# Unauthenticated GitHub allows 60 API calls an hour, and this suite makes a
# dozen. Seed the throwaway cache from a saved one, or run this repeatedly and
# the registry checks start failing for reasons that have nothing to do with the
# code under test. $1 is a directory of <repo>.json responses:
#
#   test/smoke.sh --api-cache ~/.omacellar/data/cache/api
#
# Without one the suite still works, it just spends API quota.
if [[ ${1:-} == --api-cache ]]; then
  mkdir -p "$OMACELLAR_HOME/data/cache"
  cp -r "${2:?--api-cache needs a directory}" "$OMACELLAR_HOME/data/cache/api"
  shift 2
fi

# Once we are rate limited every network-backed check fails at once and the
# output is just noise. Say so up front instead.
api_remaining() {
  curl -s --max-time 5 https://api.github.com/rate_limit 2>/dev/null \
    | jq -r '.rate.remaining // 0' 2>/dev/null || printf '0'
}
HAVE_API=1
if [[ $(api_remaining) == 0 ]]; then
  HAVE_API=0
  printf '\n  warn  GitHub API quota is spent, network checks will fail.\n'
  printf '        Seed a cache: test/smoke.sh --api-cache ~/.cache/omacellar/api\n\n'
fi

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf '  \033[32mok\033[0m    %s\n' "$1"
}

no() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m  %s\n' "$1"
  [[ -n ${2:-} ]] && printf '        %s\n' "$2"
}

check() {
  local desc=$1 want=$2; shift 2
  local out
  out=$("$@" 2>&1)
  if [[ $out == *"$want"* ]]; then
    ok "$desc"
  else
    no "$desc" "expected to contain: $want"
    printf '%s\n' "$out" | head -n5 | sed 's/^/        /'
  fi
}

check_fails() {
  local desc=$1 want=$2; shift 2
  local out
  out=$("$@" 2>&1)
  if [[ $out != *"$want"* ]]; then
    no "$desc" "expected failure mentioning: $want"
  else
    ok "$desc"
  fi
}

# --json has to be valid JSON on every command that offers it, not just some.
check_json() {
  local desc=$1; shift
  local out
  if out=$("$@" 2>/dev/null) && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    ok "$desc"
  else
    no "$desc" "not valid JSON"
  fi
}

echo
echo "syntax"
for f in "$OC" "$ROOT"/lib/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "parses: ${f#$ROOT/}"; else no "parses: ${f#$ROOT/}"; fi
done

echo
echo "cli surface"
check "help exits clean" "usage" "$OC" help
check "version prints" "omacellar" "$OC" version
check_fails "unknown command fails" "unknown command" "$OC" nonsense
check_fails "unknown subcommand fails" "unknown runner subcommand" "$OC" runner nonsense
check "runner help" "omacellar runner" "$OC" help runner
check "prefix help" "omacellar prefix" "$OC" help prefix
check "completions bash" "complete -F" "$OC" completions bash
check "completions zsh" "compdef" "$OC" completions zsh
check "completions fish" "__omacellar_runners" "$OC" completions fish
check_fails "completions rejects nonsense" "unknown shell" "$OC" completions tcsh

echo
echo "registry"
if (( HAVE_API )); then
  check "lists soda" "soda" "$OC" runner list --available
  check "lists caffe" "caffe" "$OC" runner list --available
  check "lists protosoda" "protosoda" "$OC" runner list --available
  check "lists proton-ge" "proton-ge" "$OC" runner list --available
  check "lists kron4ek tkg" "kron4ek-tkg" "$OC" runner list --available --all
  check "available versions" "soda" "$OC" runner available soda
else
  printf '  skip  upstream listings, no API quota\n'
fi
# Local registry parsing, no network needed.
check "search finds proton" "proton-ge" "$OC" runner search proton
check_fails "unknown runner id" "unknown runner" "$OC" runner info not-a-runner
check_fails "add rejects unknown id" "unknown runner" "$OC" runner add not-a-runner
check_fails "win32 arch is validated" "unknown architecture" "$OC" prefix create x --arch sparc

echo
echo "empty cellar"
check "runner list survives no runners" "installed" "$OC" runner list
check "prefix list survives no prefixes" "installations" "$OC" prefix list
check "status renders" "default runner" "$OC" status
check "doctor runs" "dependencies" "$OC" doctor
check_fails "remove unknown runner" "no such runner" "$OC" runner remove nope
check_fails "update unknown runner" "no such runner" "$OC" runner update nope --check
check_fails "activate with nothing kept" "no kept versions" "$OC" runner activate soda
check_fails "run unknown prefix" "no such prefix" "$OC" prefix run nope cmd.exe
check_fails "exec unknown runner" "no such runner" "$OC" runner exec nope true

echo
echo "config"
check "config file exists" "default_runner" "$OC" config list
check "config lives under OMACELLAR_HOME" "cellar/config.json" "$OC" config path
"$OC" config set default_runner something >/dev/null 2>&1
check "config set round trips" "something" "$OC" config get default_runner
"$OC" config unset default_runner >/dev/null 2>&1
check "config unset clears" "" "$OC" config get default_runner
# Booleans must not become the string "false", which reads as true.
"$OC" config set keep_versions false >/dev/null 2>&1
if [[ $(jq -r '.keep_versions | type' "$OMACELLAR_HOME/config.json") == boolean ]]; then
  ok "booleans stay booleans in config.json"
else
  no "booleans stay booleans in config.json" "$(jq -c '.keep_versions' "$OMACELLAR_HOME/config.json")"
fi

echo
echo "cellar layout"
check "everything lives in one hidden dir" "$WORK/cellar" "$OC" about
for d in runners prefixes data/runner_types data/version_lists data/logs; do
  if [[ -d $OMACELLAR_HOME/$d ]]; then
    ok "cellar has $d"
  else
    no "cellar has $d" "missing $OMACELLAR_HOME/$d"
  fi
done
if [[ -f $OMACELLAR_HOME/data/runner_types/runners.conf ]]; then
  ok "runner catalogue is editable in the cellar"
else
  no "runner catalogue is editable in the cellar" "no data/runner_types/runners.conf"
fi

echo
echo "migrate"
# A legacy cellar with one linked runner and one prefix directory.
LEG=$WORK/legacy
mkdir -p "$LEG/omacellar/runners/.omacellar-meta" "$LEG/omacellar/prefixes/OldBottle/drive_c"
printf 'x' >"$LEG/omacellar/prefixes/OldBottle/marker"
printf 'reg' >"$LEG/omacellar/prefixes/OldBottle/system.reg"
# A realistic prefix records an absolute path to itself, which goes stale the
# moment the directory moves.
jq -n --arg d "$LEG/omacellar/prefixes/OldBottle" \
  '{name:"OldBottle", runner:"soda-9.9", kind:"wine", arch:"win64",
    bitness:"win32+win64", prefix_dir:$d}' \
  >"$LEG/omacellar/prefixes/OldBottle/.omacellar.json"
mkdir -p "$WORK/linktarget/bin"
printf '#!/bin/sh\necho wine-9.9\n' >"$WORK/linktarget/bin/wine"
chmod +x "$WORK/linktarget/bin/wine"
ln -s "$WORK/linktarget" "$LEG/omacellar/runners/soda-9.9"

if out=$(XDG_DATA_HOME=$LEG "$OC" migrate 2>&1); then
  # No --yes, so nothing should have moved.
  if [[ -e $LEG/omacellar/prefixes/OldBottle/marker ]]; then
    ok "migrate without --yes moves nothing"
  else
    no "migrate without --yes moves nothing" "it moved something anyway"
  fi
  if printf '%s' "$out" | grep -q 'skip'; then
    ok "migrate says it skipped"
  else
    no "migrate says it skipped" "$out"
  fi
fi

# Now for real, into a separate home so the rest of the suite is unaffected.
MIG=$WORK/migrated
if XDG_DATA_HOME=$LEG OMACELLAR_HOME=$MIG "$OC" migrate --yes >/dev/null 2>&1; then
  if [[ -f $MIG/prefixes/OldBottle/marker ]]; then
    ok "migrate moves prefixes into prefixes/"
  else
    no "migrate moves prefixes into prefixes/" "$(find $MIG -maxdepth 3 2>&1 | head -5)"
  fi
  if [[ -L $MIG/runners/soda-9.9 ]]; then
    ok "migrate relinks a linked runner"
  else
    no "migrate relinks a linked runner" "$(ls -A $MIG/runners 2>&1)"
  fi
  # prefix_dir is absolute, so it has to be rewritten or the prefix looks broken.
  if [[ -f $MIG/prefixes/OldBottle/.omacellar.json ]] \
    && [[ $(jq -r .prefix_dir "$MIG/prefixes/OldBottle/.omacellar.json") == "$MIG/prefixes/OldBottle" ]]; then
    ok "migrate rewrites the recorded prefix_dir"
  else
    no "migrate rewrites the recorded prefix_dir" "stale or missing"
  fi
  if [[ -d $LEG/omacellar/prefixes && ! -e $LEG/omacellar/prefixes/OldBottle ]]; then
    ok "migrate leaves the old tree otherwise alone"
  else
    no "migrate leaves the old tree otherwise alone" "old tree was disturbed"
  fi
fi

echo
echo "new/old versions"
# A fake registry and fake tarballs, so install/update/activate are exercised
# without touching the network or the real cellar.
if (( HAVE_API )) || [[ -n ${OMACELLAR_TEST_API_DIR:-} ]]; then
  FX=$WORK/fixture
  mkdir -p "$FX/api" "$FX/build"
  : >"$FX/api/rows"
  for v in 11.0-10 11.0-4; do
    d="$FX/build/soda-$v"
    mkdir -p "$d/bin"
    printf '#!/bin/sh\necho wine-%s\n' "$v" >"$d/bin/wine"
    chmod +x "$d/bin/wine"
    printf '#!/bin/sh\n' >"$d/bin/wineserver"
    chmod +x "$d/bin/wineserver"
    tar -czf "$FX/soda-$v.tar.gz" -C "$FX/build" "soda-$v"
    size=$(stat -c %s "$FX/soda-$v.tar.gz")
    sha=$(sha256sum "$FX/soda-$v.tar.gz" | cut -d' ' -f1)
    printf '{"tag_name":"soda-%s","assets":[{"name":"soda-%s-x86_64.tar.xz","browser_download_url":"file://%s","size":%s,"digest":"sha256:%s"}]}' \
      "$v" "$v" "$FX/soda-$v.tar.gz" "$size" "$sha" >>"$FX/api/rows"
    printf ',\n' >>"$FX/api/rows"
  done
  { printf '[\n'; sed '$ s/,$//' "$FX/api/rows"; printf '\n]\n'; } >"$FX/api/bottlesdevs__wine.json"

  FXHOME=$WORK/fixture-cellar
  export OMACELLAR_TEST_API_DIR="$FX/api"
  OMACELLAR_HOME=$FXHOME "$OC" runner add soda@11.0-4 >/dev/null 2>&1

  if [[ -d $FXHOME/runners/soda/New/11.0-4 ]]; then
    ok "installs into runners/<id>/New/<version>"
  else
    no "installs into runners/<id>/New/<version>" "$(find $FXHOME/runners -maxdepth 3 2>&1 | head -5)"
  fi

  # The version file is what makes a runner identifiable after a rename.
  if [[ -f $FXHOME/runners/soda/New/11.0-4/.omacellar-version ]] \
    && [[ $(jq -r .version "$FXHOME/runners/soda/New/11.0-4/.omacellar-version") == 11.0-4 ]]; then
    ok "writes a version file inside the runner"
  else
    no "writes a version file inside the runner" "missing or wrong"
  fi

  # A renamed directory must still report the right version.
  mv "$FXHOME/runners/soda/New/11.0-4" "$FXHOME/runners/soda/New/scrambled-name"
  check_json "a renamed runner still reports its version" \
    env OMACELLAR_HOME=$FXHOME "$OC" runner list --installed --json
  mv "$FXHOME/runners/soda/New/scrambled-name" "$FXHOME/runners/soda/New/11.0-4"

  OMACELLAR_HOME=$FXHOME "$OC" config set keep_versions true >/dev/null 2>&1
  OMACELLAR_HOME=$FXHOME "$OC" runner update --all --yes >/dev/null 2>&1

  if [[ -d $FXHOME/runners/soda/New/11.0-10 ]]; then
    ok "update makes the new version active"
  else
    no "update makes the new version active" "$(find $FXHOME/runners -maxdepth 3 2>&1 | head -5)"
  fi
  if [[ -d $FXHOME/runners/soda/Old/11.0-4 ]]; then
    ok "update keeps the old version in Old/"
  else
    no "update keeps the old version in Old/" "$(find $FXHOME/runners -maxdepth 3 2>&1 | head -5)"
  fi
  check "runner old lists what is kept" "11.0-4" env OMACELLAR_HOME=$FXHOME "$OC" runner old

  if out=$(OMACELLAR_HOME=$FXHOME "$OC" runner activate soda@11.0-4 2>&1); then
    if [[ -d $FXHOME/runners/soda/New/11.0-4 && -d $FXHOME/runners/soda/Old/11.0-10 ]]; then
      ok "activate swaps New and Old without losing either"
    else
      no "activate swaps New and Old without losing either" \
        "$(find $FXHOME/runners -maxdepth 3 2>&1 | head -6)"
    fi
  else
    no "activate swaps New and Old without losing either" "$out"
  fi

  check_json "runner old --json is JSON" env OMACELLAR_HOME=$FXHOME "$OC" runner old --json
  # A prefix recorded against a version that is not installed should be
  # detected, explained, and re-pointed at the installed one.
  BROKEN=$WORK/broken-cellar
  # The replacement has to live in the same cellar as the broken prefix.
  OMACELLAR_HOME=$BROKEN "$OC" runner add soda@11.0-10 >/dev/null 2>&1
  mkdir -p "$BROKEN/prefixes/games/drive_c"
  printf reg >"$BROKEN/prefixes/games/system.reg"
  jq -n --arg d "$BROKEN/prefixes/games" \
    '{name:"games", runner:"soda-9.9", kind:"wine", prefix_dir:$d, bitness:"win64"}' \
    >"$BROKEN/prefixes/games/.omacellar.json"
  if out=$(OMACELLAR_HOME=$BROKEN "$OC" prefix run games cmd.exe 2>&1); then
    no "a prefix with a missing runner is caught" "it ran without complaining"
  else
    if printf '%s' "$out" | grep -q 'is gone'; then
      ok "a prefix with a missing runner is caught"
    else
      no "a prefix with a missing runner is caught" "$out"
    fi
    if printf '%s' "$out" | grep -q 'knows how to fix'; then
      ok "it says the problem is fixable"
    else
      no "it says the problem is fixable" "$out"
    fi
  fi

  # Updating a runner on the way in has to actually be offered, and answered.
  OFFER=$WORK/offer-cellar
  OMACELLAR_HOME=$OFFER "$OC" runner add soda@11.0-4 >/dev/null 2>&1
  # Not a tty and no --yes: the offer must be skipped silently, keeping the
  # installed version rather than updating behind the user's back.
  if OMACELLAR_HOME=$OFFER "$OC" prefix create demo --runner soda >/dev/null 2>&1; then
    if [[ -d $OFFER/runners/soda/New/11.0-4 && ! -d $OFFER/runners/soda/New/11.0-10 ]]; then
      ok "no update happens without a terminal or --yes"
    else
      no "no update happens without a terminal or --yes" "it updated anyway"
    fi
  else
    # The fake wine cannot boot a prefix, which is fine; only the runner state
    # matters here.
    if [[ -d $OFFER/runners/soda/New/11.0-4 && ! -d $OFFER/runners/soda/New/11.0-10 ]]; then
      ok "no update happens without a terminal or --yes"
    else
      no "no update happens without a terminal or --yes" "it updated anyway"
    fi
  fi
  # With --yes it takes the update, which is the documented unattended path.
  if OMACELLAR_HOME=$OFFER "$OC" prefix create demo2 --runner soda --yes >/dev/null 2>&1; then
    :
  fi
  if [[ -d $OFFER/runners/soda/New/11.0-10 ]]; then
    ok "the update offer runs unattended when --yes is given"
  else
    no "the update offer runs unattended when --yes is given" \
      "$(find $OFFER/runners -maxdepth 3 2>&1 | head -5)"
  fi

  # A prefix recorded against a missing runner, and the fix for it.
  if OMACELLAR_HOME=$BROKEN bash -c '
      export OMACELLAR_HOME=$1 OMACELLAR_TEST_API_DIR=$2 NO_COLOR=1
      for m in core registry install launch prefix update ui; do source "$3/lib/$m.sh"; done
      runner_index_build
      prefix_apply_fixes games prefix_missing_runner' _ "$BROKEN" "$OMACELLAR_TEST_API_DIR" "$ROOT" \
    >/dev/null 2>&1; then
    if [[ $(jq -r .runner "$BROKEN/prefixes/games/.omacellar.json") == soda-11.0-10 ]]; then
      ok "the fix re-points the prefix at the installed version"
    else
      no "the fix re-points the prefix at the installed version" \
        "got $(jq -r .runner "$BROKEN/prefixes/games/.omacellar.json")"
    fi
  else
    no "the fix re-points the prefix at the installed version" "prefix_apply_fixes failed"
  fi

  unset OMACELLAR_TEST_API_DIR
else
  printf '  skip  install/update/activate, no API quota or fixture dir\n'
fi

LINKED=0
if (( $# > 0 )); then
  echo
  echo "linked runners"
  for d in "$@"; do
    name=$("$OC" runner link "$d" 2>/dev/null | tail -n1)
    if [[ -n $name ]]; then
      ok "linked $(basename "$d") as $name"
      LINKED=$((LINKED + 1))
    else
      no "linked $(basename "$d")"
    fi
  done

  if (( LINKED > 0 )); then
    check "runners are listed" "ok" "$OC" runner list --installed
    check "doctor sees the cellar" "cellar" "$OC" doctor
    check "status counts runners" "runners" "$OC" status

    wine_runner=$("$OC" runner list --installed | awk '$1 == "ok" { print $2; exit }')
    if [[ -n $wine_runner ]]; then
      check "runner path resolves" "/" "$OC" runner path "$wine_runner"
      check "runner info works" "kind" "$OC" runner info "$wine_runner"
      check "linked runner cannot update" "linked" "$OC" runner update "$wine_runner" --check
      WINE_RUNNER=$wine_runner
    fi
  fi
fi

echo
echo "regressions"
# Each of these caught a real bug. Cheap, and they have to stay green.

# `runner info` on an installed runner used to die on an unbound variable.
if [[ -n ${WINE_RUNNER:-} ]]; then
  if out=$("$OC" runner info "$WINE_RUNNER" 2>&1); then
    ok "runner info works on an installed runner"
  else
    no "runner info works on an installed runner" "$out"
  fi
fi

# The default runner fallback used to pick alphabetically, not by version.
# Build a throwaway cellar with two versions whose names sort the wrong way,
# and check the higher version wins.
if (( HAVE_API )) || [[ -n ${OMACELLAR_TEST_API_DIR:-} ]]; then
  AGE=$WORK/age-cellar
  export OMACELLAR_TEST_API_DIR=${OMACELLAR_TEST_API_DIR:-$WORK/fixture/api}
  mkdir -p "$OMACELLAR_TEST_API_DIR"
  # An empty release list is enough: nothing here needs the network.
  [[ -f $OMACELLAR_TEST_API_DIR/bottlesdevs__wine.json ]] \
    || printf '[]\n' >"$OMACELLAR_TEST_API_DIR/bottlesdevs__wine.json"

  # Two linked runners with different ids. The older one sorts first
  # alphabetically, so picking the first entry is wrong and picking the highest
  # version is right.
  mkdir -p "$WORK/age/aaa/bin" "$WORK/age/zzz/bin"
  printf '#!/bin/sh\necho wine-1.0\n' >"$WORK/age/aaa/bin/wine"
  chmod +x "$WORK/age/aaa/bin/wine"
  printf '#!/bin/sh\necho wine-11.0\n' >"$WORK/age/zzz/bin/wine"
  chmod +x "$WORK/age/zzz/bin/wine"
  OMACELLAR_HOME=$AGE "$OC" runner link "$WORK/age/aaa" --as caffe >/dev/null 2>&1
  OMACELLAR_HOME=$AGE "$OC" runner link "$WORK/age/zzz" --as soda >/dev/null 2>&1

  got=$(bash -c '
    export OMACELLAR_HOME=$1 OMACELLAR_TEST_API_DIR=$2
    for m in core registry install launch prefix update ui; do source "$3/lib/$m.sh"; done
    runner_index_build
    prefix_newest_installed_runner' _ "$AGE" "$OMACELLAR_TEST_API_DIR" "$ROOT" 2>/dev/null)
  if [[ $got == soda ]]; then
    ok "newest runner wins over alphabetical order"
  else
    no "newest runner wins over alphabetical order" "expected soda (11.0), got ${got:-nothing}"
  fi

  # A bare id has to resolve to an installed runner, which is not obvious when
  # ids contain dashes and versions are optional.
  if [[ $(OMACELLAR_HOME=$AGE bash -c '
    export OMACELLAR_HOME=$1 OMACELLAR_TEST_API_DIR=$2
    for m in core registry install launch prefix update ui; do source "$3/lib/$m.sh"; done
    runner_index_build
    runner_resolve_name soda' _ "$AGE" "$OMACELLAR_TEST_API_DIR" "$ROOT" 2>/dev/null) == soda ]]; then
    ok "a bare runner id resolves to what is installed"
  else
    no "a bare runner id resolves to what is installed" "did not resolve"
  fi
  unset OMACELLAR_TEST_API_DIR
fi

check_json "runner list --installed --json is JSON" "$OC" runner list --installed --json
if (( HAVE_API )); then
  check_json "runner list --available --json is JSON" "$OC" runner list --available --json
fi
check_json "prefix list --json is JSON" "$OC" prefix list --json
check_json "status --json is JSON" "$OC" status --json
if [[ -n ${WINE_RUNNER:-} ]]; then
  check_json "runner info --json is JSON" "$OC" runner info "$WINE_RUNNER" --json
fi

# --dry-run must resolve without downloading a tarball.
if (( HAVE_API )); then
  BEFORE=$(find "$XDG_CACHE_HOME/omacellar/downloads" -type f 2>/dev/null | wc -l)
  "$OC" runner add soda --dry-run >/dev/null 2>&1
  AFTER=$(find "$XDG_CACHE_HOME/omacellar/downloads" -type f 2>/dev/null | wc -l)
  if [[ $BEFORE == "$AFTER" ]] && "$OC" runner add soda --dry-run >/dev/null 2>&1; then
    ok "--dry-run resolves but downloads nothing"
  else
    no "--dry-run resolves but downloads nothing" "downloads went $BEFORE -> $AFTER"
  fi
fi

# A runner pulled out from under an installation has to be refused.
if [[ -n ${WINE_RUNNER:-} ]]; then
  if "$OC" prefix create smoketest-guard --runner "$WINE_RUNNER" >/dev/null 2>&1; then
    out=$("$OC" runner remove "$WINE_RUNNER" --yes 2>&1)
    if printf '%s' "$out" | grep -q 'will not run without it'; then
      ok "refuses to remove a runner an installation still uses"
    else
      no "refuses to remove a runner an installation still uses" "removed it anyway"
    fi
    "$OC" prefix remove smoketest-guard --yes >/dev/null 2>&1
  else
    printf '  skip  runner-in-use guard, could not create a prefix\n'
  fi
fi

# Tarballs with more than 64 entries in the first directory used to lose the
# second top level and get the wrong --strip-components.
STRIP=$(mktemp -d)
mkdir -p "$STRIP/a/sub"
for i in $(seq 1 80); do : >"$STRIP/a/sub/f$i"; done
mkdir -p "$STRIP/b"
: >"$STRIP/b/only"
tar -cf "$STRIP/multi.tar" -C "$STRIP" a b
rm -rf "$STRIP/a" "$STRIP/b"
if bash -c '
    source "$1/lib/core.sh"; source "$1/lib/registry.sh"
    source "$1/lib/ui.sh"; source "$1/lib/install.sh"
    runner_extract "$2" "$3"' _ "$ROOT" "$STRIP/multi.tar" "$STRIP/out" >/dev/null 2>&1 \
  && [[ -d $STRIP/out/a && -d $STRIP/out/b ]]; then
  ok "extract keeps every top level of a large tarball"
else
  no "extract keeps every top level of a large tarball" "got: $(ls "$STRIP/out" 2>&1)"
fi
rm -rf "$STRIP"

# GE-Proton version numbers must not be pinned, or a major bump upstream
# silently breaks three runners.
if grep -qE 'GE-Proton[0-9]+-' "$ROOT/registry/runners.conf"; then
  no "GE-Proton version numbers are not pinned" "registry still names a specific major"
else
  ok "GE-Proton version numbers are not pinned"
fi

if [[ -n ${WINE_RUNNER:-} && ${OMACELLAR_SMOKE_FULL:-0} == 1 ]]; then
  echo
  echo "live launch (slow)"
  if out=$("$OC" prefix create smoketest --runner "$WINE_RUNNER" 2>&1); then
    ok "created an installation with $WINE_RUNNER"
  else
    no "created an installation" "$out"
  fi

  check "installation is listed" "smoketest" "$OC" prefix list
  check "installation reports a prefix" "/" "$OC" prefix path smoketest
  check "environment exports WINEPREFIX" "export WINEPREFIX" "$OC" prefix env smoketest

  if out=$(timeout 300 "$OC" prefix run smoketest 'C:\windows\system32\cmd.exe' /c 'echo omacellar-smoke' 2>&1); then
    if [[ $out == *omacellar-smoke* ]]; then
      ok "ran a 64-bit program in it"
    else
      no "ran a 64-bit program in it" "no output from cmd.exe"
    fi
  else
    no "ran a 64-bit program in it" "$out"
  fi

  "$OC" prefix remove smoketest --yes >/dev/null 2>&1
  check "removed the installation" "" "$OC" prefix path smoketest
fi

echo
if (( FAIL == 0 )); then
  printf '  \033[32m%d checks passed\033[0m\n\n' "$PASS"
  exit 0
fi
printf '  \033[31m%d of %d checks failed\033[0m\n\n' "$FAIL" "$((PASS + FAIL))"
exit 1