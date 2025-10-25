# Configuracion generada para Powerlevel10k
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
  os_icon
  dir
  vcs
)

typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
  status
  command_execution_time
  background_jobs
  time
)

typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true
typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_PREFIX="%F{81}->%f "
typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_PREFIX="%F{81}=>%f "

typeset -g POWERLEVEL9K_DIR_FOREGROUND=110
typeset -g POWERLEVEL9K_DIR_BACKGROUND=17
typeset -g POWERLEVEL9K_VCS_FOREGROUND=39
typeset -g POWERLEVEL9K_VCS_BACKGROUND=17
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=39
typeset -g POWERLEVEL9K_STATUS_OK_BACKGROUND=17

[[ ! -f ~/.p10k.zsh.local ]] || source ~/.p10k.zsh.local

