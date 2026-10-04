# bash completion for omacellar
# Install with: omacellar completions bash > ~/.local/share/bash-completion/completions/omacellar

_omacellar_runners() {
  omacellar runner list --installed 2>/dev/null |
    awk 'NR > 2 && $1 ~ /^(ok|broken)$/ { print $2 }'
}

_omacellar_prefixes() {
  omacellar prefix list 2>/dev/null |
    awk 'NR > 2 && ($1 == "ok" || $1 == "broken") { print $2 }'
}

_omacellar_registry_ids() {
  local ids
  ids=$(omacellar runner list --available --all 2>/dev/null | awk 'NR > 1 && $1 != "ID" { print $1 }')
  printf '%s\n' $ids
}

_omacellar() {
  local cur prev words cword
  cur=${COMP_WORDS[COMP_CWORD]}
  prev=${COMP_WORDS[COMP_CWORD - 1]}

  local commands="runner prefix status doctor config completions about migrate help version"
  local runner_commands="list search info available add remove update link unlink adopt path steam unsteam exec old activate"
  local prefix_commands="list create remove info path run shell winetricks env"
  local global_flags="--json --refresh --yes --all --force --check"

  case $prev in
    runner | runners | r)
      case $cur in
        -*) COMPREPLY=($(compgen -W "--all --installed --available --refresh --force --check --yes --json --dry-run --insecure --as" -- "$cur")) ;;
        *)
          COMPREPLY=($(compgen -W "$runner_commands $(_omacellar_runners) $(_omacellar_registry_ids)" -- "$cur"))
          ;;
      esac
      return 0
      ;;
    prefix | prefixes | p)
      case $cur in
        -*) COMPREPLY=($(compgen -W "--runner --arch --force --yes --json --no-fix --no-update-check" -- "$cur")) ;;
        *)
          case ${COMP_WORDS[2]} in
            remove | rm | delete | info | show | path | run | shell | winetricks | wt | env)
              COMPREPLY=($(compgen -W "$(_omacellar_prefixes)" -- "$cur"))
              ;;
            *)
              COMPREPLY=($(compgen -W "$prefix_commands" -- "$cur"))
              ;;
          esac
          ;;
      esac
      return 0
      ;;
    completions)
      COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
      return 0
      ;;
  esac

  case ${COMP_WORDS[1]} in
    runner | runners | r)
      case ${COMP_WORDS[2]} in
        remove | rm | uninstall | update | path | info | unlink)
          COMPREPLY=($(compgen -W "$(_omacellar_runners)" -- "$cur"))
          ;;
        add | available)
          COMPREPLY=($(compgen -W "$(_omacellar_registry_ids)" -- "$cur"))
          ;;
        --runner)
          COMPREPLY=($(compgen -W "$(_omacellar_runners) $(_omacellar_registry_ids)" -- "$cur"))
          ;;
        --arch)
          COMPREPLY=($(compgen -W "win64 win32 both" -- "$cur"))
          ;;
      esac
      ;;
    config)
      case ${COMP_WORDS[2]} in
        set | get | unset)
          COMPREPLY=($(compgen -W "default_runner runners_dir prefix_dir channel keep_versions api_cache_ttl runner_env steam_compat_tools show_experimental" -- "$cur"))
          ;;
      esac
      ;;
    *)
      case $cur in
        -*) COMPREPLY=($(compgen -W "$global_flags" -- "$cur")) ;;
        *) COMPREPLY=($(compgen -W "$commands" -- "$cur")) ;;
      esac
      ;;
  esac
  return 0
}

complete -F _omacellar omacellar