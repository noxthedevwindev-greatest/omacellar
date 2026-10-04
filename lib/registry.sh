#!/usr/bin/env bash
# omacellar :: registry
# The catalogue of known runners and the GitHub resolution behind it.

[[ -n "${_OMACELLAR_REGISTRY:-}" ]] && return 0
_OMACELLAR_REGISTRY=1

declare -gA REG_REC=()
declare -ga REG_IDS=()

readonly RF_ID=1 RF_FAMILY=2 RF_TITLE=3 RF_REPO=4 RF_KIND=5 RF_VER_RE=6 \
  RF_ASSET_RE=7 RF_ARCHES=8 RF_CHANNEL=9 RF_HOMEPAGE=10 RF_DESC=11

registry_file() {
  # The editable copy in the cellar wins; the packaged one is only a seed.
  local user="$(runner_types_dir)/runners.conf"
  if [[ -f $user ]]; then
    printf '%s\n' "$user"
  else
    printf '%s\n' "$OMACELLAR_REGISTRY_FILE"
  fi
}

registry_load() {
  [[ ${#REG_IDS[@]} -gt 0 ]] && return 0
  local f line id
  f=$(registry_file)
  [[ -f $f ]] || die "registry not found: $f"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%$'\r'}
    [[ -z ${line//[[:space:]]/} ]] && continue
    [[ $line == \#* ]] && continue
    [[ $line != *"|"* ]] && continue
    id=${line%%|*}
    id=${id//[[:space:]]/}
    [[ -z $id ]] && continue
    REG_REC[$id]=$line
    REG_IDS+=("$id")
  done <"$f"
  return 0
}

reg_exists() { registry_load; [[ -n ${REG_REC[$1]:-} ]]; }

reg_get() {
  registry_load
  local rec=${REG_REC[$1]:-} n=$2 i=1 field
  [[ -n $rec ]] || return 1
  while :; do
    if [[ $rec == *"|"* ]]; then
      field=${rec%%|*}
      rec=${rec#*|}
    else
      field=$rec
      rec=""
    fi
    if (( i == n )); then
      printf '%s\n' "$field"
      return 0
    fi
    [[ -n $rec ]] || return 1
    ((i++))
  done
}

reg_title() { reg_get "$1" $RF_TITLE; }
reg_repo() { reg_get "$1" $RF_REPO; }
reg_kind() { reg_get "$1" $RF_KIND; }
reg_ver_re() { reg_get "$1" $RF_VER_RE; }
reg_asset_re() { reg_get "$1" $RF_ASSET_RE; }
reg_arches() { reg_get "$1" $RF_ARCHES; }
reg_channel() { reg_get "$1" $RF_CHANNEL; }
reg_homepage() { reg_get "$1" $RF_HOMEPAGE; }
reg_desc() { reg_get "$1" $RF_DESC; }
reg_family() { reg_get "$1" $RF_FAMILY; }

reg_supports_host() {
  local arches; arches=$(reg_arches "$1") || return 1
  [[ -z $arches ]] && return 0
  [[ ,$arches, == *",$(host_arch),"* ]]
}

# ------------------------------------------------------------ escaping ----

regex_escape() { printf '%s\n' "$1" | sed 's/[][\.^$*+?(){}|\\/]/\\&/g'; }

expand_asset_re() {
  local pattern=$1 ver=$2 arch
  arch=$(host_arch)
  pattern=${pattern//\{ver\}/$(regex_escape "$ver")}
  pattern=${pattern//\{arch\}/$(regex_escape "$arch")}
  printf '%s\n' "$pattern"
}

reg_ver_from_tag() {
  local id=$1 tag=$2 re
  re=$(reg_ver_re "$id") || return 1
  [[ -z $re ]] && return 1
  [[ $tag =~ $re ]] || return 1
  local ver=${BASH_REMATCH[1]}
  [[ -n $ver ]] || return 1
  printf '%s\n' "$ver"
}

# ----------------------------------------------------------- github api ----

github_token() { printf '%s\n' "${GITHUB_TOKEN:-${GH_TOKEN:-}}"; }

# Tests point this at a fixture directory instead of api.github.com. The
# layout matches the real cache, so the caching logic itself gets exercised.
github_fixture_dir() { printf '%s\n' "${OMACELLAR_TEST_API_DIR:-}"; }

github_releases() {
  local repo=$1 force=${2:-false}
  local cache ttl url tmp
  cache="$(api_cache_dir)/${repo//\//__}.json"
  ttl=$(config_get api_cache_ttl 21600)
  mkdir -p "$(api_cache_dir)"

  local fixture; fixture=$(github_fixture_dir)
  if [[ -n $fixture ]]; then
    local f="$fixture/${repo//\//__}.json"
    if [[ -f $f ]]; then
      printf '%s\n' "$f"
      return 0
    fi
    # An empty array is a valid answer: the repo exists, it just has no
    # matching releases.
    [[ $force == true ]] || true
    printf '[]\n'
    return 0
  fi

  if [[ $force == false && -f $cache ]]; then
    if [[ $ttl == 0 ]]; then
      log_dim "  (api cache disabled, querying $repo)"
    else
      local age=$(( $(date +%s) - $(stat -c %Y "$cache") ))
      if (( age < ttl )); then
        printf '%s\n' "$cache"
        return 0
      fi
    fi
  fi

  url="https://api.github.com/repos/$repo/releases?per_page=100"
  local -a headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  local token; token=$(github_token)
  [[ -n $token ]] && headers+=(-H "Authorization: Bearer $token")

  tmp=$(mktemp)
  if ! curl -fsSL "${headers[@]}" "$url" -o "$tmp" 2>/dev/null; then
    if grep -q 'API rate limit exceeded' "$tmp" 2>/dev/null; then
      log_warn "GitHub API rate limit hit for $repo."
      log_hint "export GITHUB_TOKEN=... to raise the limit, or wait an hour."
    else
      log_warn "could not reach api.github.com for $repo"
    fi
    rm -f "$tmp"
    # Falling back to a stale cache silently is how you end up believing a
    # runner is current when it is two versions behind. Say so.
    if [[ -f $cache ]]; then
      local age=$(( $(date +%s) - $(stat -c %Y "$cache") ))
      log_warn "using cached data for $repo, $(human_age "$age") old"
      printf '%s\n' "$cache"
      return 0
    fi
    return 1
  fi

  if ! jq -e 'type == "array"' "$tmp" >/dev/null 2>&1; then
    log_warn "unexpected API payload for $repo"
    rm -f "$tmp"
    [[ -f $cache ]] && { printf '%s\n' "$cache"; return 0; }
    return 1
  fi

  mv -f "$tmp" "$cache"
  printf '%s\n' "$cache"
}

github_tags() {
  local repo=$1 force=${2:-false} json
  json=$(github_releases "$repo" "$force") || return 1
  jq -r '.[].tag_name' "$json" 2>/dev/null
}

github_release_asset() {
  local repo=$1 tag=$2 are=$3 json
  json=$(github_releases "$repo") || return 1
  jq -r --arg tag "$tag" --arg re "$are" '
    (.[] | select(.tag_name == $tag)) as $rel
    | ($rel.assets // [])[]
    | select(.name | test($re))
    | [.name, .browser_download_url, (.size // 0), (.digest // "")] | @tsv
  ' "$json" 2>/dev/null | head -n1
}

# --------------------------------------------------------- version index ----

runner_versions() {
  local id=$1 repo tags tag ver
  reg_exists "$id" || return 1
  repo=$(reg_repo "$id") || return 1
  [[ -z $repo ]] && return 1
  tags=$(github_tags "$repo") || return 1
  while IFS= read -r tag; do
    [[ -z $tag ]] && continue
    if ver=$(reg_ver_from_tag "$id" "$tag"); then
      printf '%s\t%s\n' "$ver" "$tag"
    fi
  done <<<"$tags" | sort -t$'\t' -k1,1Vr
}

runner_latest_version() {
  runner_versions "$1" 2>/dev/null | head -n1
}

runner_resolve() {
  local id=$1 want=${2:-} repo tag ver are line
  reg_exists "$id" || { log_err "unknown runner: $id"; return 1; }
  repo=$(reg_repo "$id")
  if [[ -z $repo ]]; then
    log_err "runner '$id' has no upstream (system runners are not installed)"
    return 1
  fi

  R_VER= R_TAG= R_ASSET= R_URL= R_SIZE= R_DIGEST=

  local best_ver= best_tag=
  while IFS=$'\t' read -r ver tag; do
    [[ -z $ver ]] && continue
    if [[ -n $want ]]; then
      if [[ $ver == "$want" ]]; then
        best_ver=$ver; best_tag=$tag; break
      fi
      [[ $tag == "$want" ]] && { best_ver=$ver; best_tag=$tag; break; }
      continue
    fi
    if [[ -z $best_ver ]] || version_gt "$ver" "$best_ver"; then
      best_ver=$ver; best_tag=$tag
    fi
  done < <(runner_versions "$id")

  if [[ -z $best_ver ]]; then
    if [[ -n $want ]]; then
      log_err "$id has no release matching version '$want'"
      log_hint "available: $(runner_versions "$id" | cut -f1 | tr '\n' ' ')"
    else
      log_err "no releases found for $id ($repo)"
    fi
    return 1
  fi

  are=$(expand_asset_re "$(reg_asset_re "$id")" "$best_ver")
  line=$(github_release_asset "$repo" "$best_tag" "$are") || true
  if [[ -z $line ]]; then
    log_err "$id $best_ver has no build for $(host_arch) (matched no asset against /$are/)"
    if ! reg_supports_host "$id"; then
      log_hint "this runner is published for: $(reg_arches "$id")"
    else
      log_hint "the upstream asset naming may have changed; check $(reg_homepage "$id")"
    fi
    return 1
  fi

  IFS=$'\t' read -r R_ASSET R_URL R_SIZE R_DIGEST <<<"$line"
  R_VER=$best_ver
  R_TAG=$best_tag
  return 0
}