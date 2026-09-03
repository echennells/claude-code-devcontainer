# shellcheck shell=bash
# Zsh configuration for Claude Code devcontainer

# Add Claude Code to PATH
export PATH="$HOME/.local/bin:$PATH"

# fnm (Fast Node Manager)
export FNM_DIR="$HOME/.fnm"
export PATH="$FNM_DIR:$PATH"
eval "$(fnm env --use-on-cd)"

# One hook owns the whole shim order. Neither vendor pin survives on its own:
# two functions each racing their own dir to the front means whichever runs
# last wins, and the loser's layer is silently skipped.
#
# Order is Safe Chain -> sbe -> real binary, and it is deliberate. Safe Chain
# must sit OUTSIDE the cage: it needs to reach intel.aikido.dev, which is not
# on any sbe profile's allowlist (a CONNECT there returns 403), and sbe will
# not exec its binary anyway since it is not in allowExec. Outside the cage it
# screens first, then hands the install to the sbe shim, which cages it.
#
# Both vendor shims resolve their target by stripping only their own directory
# from PATH and re-running `command -v`, so they chain without knowing about
# each other.
#
# Runs on precmd as well as chpwd: `cd` alone leaves a window open after any
# PATH-prepending event that is not a directory change -- venv activate,
# direnv, conda, nvm use -- during which the shims are shadowed.
_pin_supply_chain_shims() {
  local sc="$HOME/.safe-chain/shims" sb="/usr/local/bin/sbe-shims"
  local p="$PATH"
  p="${p//$sc:/}"; p="${p%:$sc}"
  p="${p//$sb:/}"; p="${p%:$sb}"
  export PATH="$sc:$sb:$p"
}
_pin_supply_chain_shims
autoload -U add-zsh-hook
add-zsh-hook chpwd  _pin_supply_chain_shims
add-zsh-hook precmd _pin_supply_chain_shims

# History settings
export HISTFILE=/commandhistory/.zsh_history
export HISTSIZE=200000
export SAVEHIST=200000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS    # Remove older duplicate entries
setopt HIST_REDUCE_BLANKS      # Remove extra blanks from commands
setopt HIST_VERIFY             # Show command before executing from history

# Directory navigation
setopt AUTO_CD                 # cd by typing directory name
setopt AUTO_PUSHD              # Push directories onto stack
setopt PUSHD_IGNORE_DUPS       # Don't push duplicates
setopt PUSHD_SILENT            # Don't print stack after pushd/popd

# Completion
setopt COMPLETE_IN_WORD        # Complete from both ends of word
setopt ALWAYS_TO_END           # Move cursor to end after completion

# Aliases
alias fd=fdfind
alias sg=ast-grep
alias claude-yolo='claude --dangerously-skip-permissions'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'

# fzf configuration - use fd for faster file finding
export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --follow --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fdfind --type d --hidden --follow --exclude .git'
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border --info=inline'

# Use fd for ** completion (e.g., vim **)
_fzf_compgen_path() {
  fdfind --hidden --follow --exclude .git . "$1"
}
_fzf_compgen_dir() {
  fdfind --type d --hidden --follow --exclude .git . "$1"
}

# Source fzf shell integration (built-in since fzf 0.48+)
eval "$(fzf --zsh)"
