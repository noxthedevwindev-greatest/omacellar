# fish completion for omacellar
# Install with: omacellar completions fish > ~/.config/fish/completions/omacellar.fish

function __omacellar_runners
    omacellar runner list --installed 2>/dev/null | awk 'NR > 2 && ($1 == "ok" || $1 == "broken") { print $2 }'
end

function __omacellar_prefixes
    omacellar prefix list 2>/dev/null | awk 'NR > 2 && ($1 == "ok" || $1 == "broken") { print $2 }'
end

function __omacellar_registry_ids
    omacellar runner list --available --all 2>/dev/null | awk 'NR > 1 && $1 != "ID" { print $1 }'
end

complete -c omacellar -f
complete -c omacellar -n '__fish_use_subcommand' -a runner -d 'manage runners'
complete -c omacellar -n '__fish_use_subcommand' -a prefix -d 'manage installations'
complete -c omacellar -n '__fish_use_subcommand' -a status -d 'one screen summary'
complete -c omacellar -n '__fish_use_subcommand' -a about -d 'who made this'
complete -c omacellar -n '__fish_use_subcommand' -a migrate -d 'adopt a cellar from an older layout'
complete -c omacellar -n '__fish_use_subcommand' -a doctor -d 'check the machine'
complete -c omacellar -n '__fish_use_subcommand' -a config -d 'read and write configuration'
complete -c omacellar -n '__fish_use_subcommand' -a completions -d 'print shell completions'
complete -c omacellar -n '__fish_use_subcommand' -a help -d 'show help'
complete -c omacellar -n '__fish_use_subcommand' -a version -d 'print the version'

complete -c omacellar -n '__fish_seen_subcommand_from runner' -a 'list search info available add remove update link unlink adopt path steam unsteam exec old activate'
complete -c omacellar -n '__fish_seen_subcommand_from prefix' -a 'list create remove info path run shell winetricks env'
complete -c omacellar -n '__fish_seen_subcommand_from completions' -a 'bash zsh fish'

complete -c omacellar -n '__fish_seen_subcommand_from runner; and __fish_seen_subcommand_from add available' -a '(__omacellar_registry_ids)'
complete -c omacellar -n '__fish_seen_subcommand_from runner; and __fish_seen_subcommand_from remove update path info unlink' -a '(__omacellar_runners)'
complete -c omacellar -n '__fish_seen_subcommand_from runner; and __fish_seen_subcommand_from link' -F
complete -c omacellar -n '__fish_seen_subcommand_from runner' -l as -d 'registry id to record' -r
complete -c omacellar -n '__fish_seen_subcommand_from runner' -l force -d 'reinstall over the top'
complete -c omacellar -n '__fish_seen_subcommand_from runner' -l check -d 'only report'
complete -c omacellar -n '__fish_seen_subcommand_from runner' -l all -d 'include experimental and variants'
complete -c omacellar -n '__fish_seen_subcommand_from runner' -l installed -d 'only installed'
complete -c omacellar -n '__fish_seen_subcommand_from runner' -l available -d 'only upstream'
complete -c omacellar -n '__fish_seen_subcommand_from runner' -l refresh -d 'ignore the API cache'
complete -c omacellar -n '__fish_seen_subcommand_from runner' -s y -l yes -d 'do not ask'
complete -c omacellar -n '__fish_seen_subcommand_from runner' -l json -d 'machine readable output'
complete -c omacellar -n '__fish_seen_subcommand_from runner; and __fish_seen_subcommand_from add' -l dry-run -d 'report, download nothing'
complete -c omacellar -n '__fish_seen_subcommand_from runner; and __fish_seen_subcommand_from add' -l insecure -d 'continue past a bad checksum'
complete -c omacellar -n '__fish_seen_subcommand_from prefix' -l no-fix -d 'skip the offer to repair a broken prefix'
complete -c omacellar -n '__fish_seen_subcommand_from prefix; and __fish_seen_subcommand_from create' -l no-update-check -d 'do not offer a runner update'
complete -c omacellar -n '__fish_seen_subcommand_from prefix; and __fish_seen_subcommand_from list' -l json -d 'machine readable output'
complete -c omacellar -n 'not __fish_seen_subcommand_from runner prefix' -l json -d 'machine readable output'

complete -c omacellar -n '__fish_seen_subcommand_from prefix; and __fish_seen_subcommand_from create remove info path run shell winetricks env' -a '(__omacellar_prefixes)'
complete -c omacellar -n '__fish_seen_subcommand_from prefix' -l runner -d 'runner to build it with' -r -a '(__omacellar_runners)'
complete -c omacellar -n '__fish_seen_subcommand_from prefix' -l arch -d 'prefix architecture' -r -a 'win64 win32 both'
complete -c omacellar -n '__fish_seen_subcommand_from prefix' -l force -d 'recreate from scratch'
complete -c omacellar -n '__fish_seen_subcommand_from prefix' -s y -l yes -d 'do not ask'