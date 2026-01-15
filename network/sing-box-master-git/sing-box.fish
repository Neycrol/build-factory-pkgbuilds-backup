# Fish completions for sing-box
complete -c sing-box -f

complete -c sing-box -n __fish_use_subcommand -a run -d 'Run service'
complete -c sing-box -n __fish_use_subcommand -a check -d 'Check configuration'
complete -c sing-box -n __fish_use_subcommand -a format -d 'Format configuration'
complete -c sing-box -n __fish_use_subcommand -a version -d 'Print version'
