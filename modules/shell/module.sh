#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="shell"

# shellcheck source=../common.sh
source "${MODULE_DIR}/../common.sh"

ZSH_PATH="/usr/bin/zsh"

load_shell_config() {
  eval "$(
    python3 - "${CONFIG_JSON}" <<'PY'
import json
import sys
from shlex import quote

config_path = sys.argv[1]
with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)

shell = data.get("shell", {})
ohmyzsh = shell.get("ohmyzsh", {})
powerlevel = shell.get("powerlevel10k", {})
nerd_fonts = shell.get("nerd_fonts", {})

def emit_str(key, value, fallback=""):
    if value is None:
        value = fallback
    print(f"{key}={quote(str(value))}")

def emit_bool(key, value, fallback=False):
    if value is None:
        value = fallback
    print(f"{key}={'true' if value else 'false'}")

emit_str("SHELL_DEFAULT", shell.get("default"), "zsh")
emit_bool("OHMYZSH_ENABLED", ohmyzsh.get("enabled"))

plugins = ohmyzsh.get("plugins", [])
print(f"OHMYZSH_PLUGIN_COUNT={len(plugins)}")
for idx, plugin in enumerate(plugins):
    print(f"OHMYZSH_PLUGIN_{idx}={quote(str(plugin))}")

emit_bool("POWERLEVEL10K_ENABLED", powerlevel.get("enabled"))
emit_str("POWERLEVEL10K_CONFIG", powerlevel.get("config"), "")
emit_bool("POWERLEVEL10K_INSTANT", powerlevel.get("instant_prompt"))

emit_bool("NERD_FONTS_SET", nerd_fonts.get("set_for_terminals"))
fonts = nerd_fonts.get("install", [])
print(f"NERD_FONT_COUNT={len(fonts)}")
for idx, font in enumerate(fonts):
    print(f"NERD_FONT_{idx}={quote(str(font))}")
PY
  )"
}

install_zsh() {
  ensure_apt_packages zsh
}

set_default_shell() {
  local current_shell
  current_shell="$(getent passwd "${TARGET_USER}" | awk -F: '{print $7}')"

  if [[ "${current_shell}" == "${ZSH_PATH}" ]]; then
    log_info "El usuario ${TARGET_USER} ya tiene zsh como shell predeterminado."
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se cambiaria la shell predeterminada de ${TARGET_USER} a zsh."
    return
  fi

  run_cmd "Cambiando shell predeterminada" chsh -s "${ZSH_PATH}" "${TARGET_USER}"
}

install_ohmyzsh() {
  if [[ "${OHMYZSH_ENABLED}" != "true" ]]; then
    log_info "Oh-My-Zsh no esta habilitado en la configuracion."
    return
  fi

  local target_dir="${TARGET_HOME}/.oh-my-zsh"
  if [[ -d "${target_dir}" ]]; then
    log_info "Oh-My-Zsh ya se encuentra instalado en ${target_dir}."
    return
  fi

  ensure_apt_packages git curl

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se clonaria Oh-My-Zsh en ${target_dir}"
    return
  fi

  run_as_user "${TARGET_USER}" git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "${target_dir}"
}

configure_plugins() {
  local zshrc="${TARGET_HOME}/.zshrc"
  if [[ "${OHMYZSH_ENABLED}" != "true" ]]; then
    return
  fi

  local plugins=()
  local plugin_count="${OHMYZSH_PLUGIN_COUNT:-0}"
  local idx=0
  while (( idx < plugin_count )); do
    local var_name="OHMYZSH_PLUGIN_${idx}"
    local value="${!var_name:-}"
    value="${value//$'\r'/}"
    if [[ -n "${value}" ]]; then
      plugins+=("${value}")
    fi
    ((idx++))
  done

  if ((${#plugins[@]} == 0)); then
    log_info "No se declararon plugins adicionales para Oh-My-Zsh."
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se configuraria plugins: ${plugins[*]}"
    return
  fi

  if [[ ! -f "${zshrc}" ]]; then
    run_as_user "${TARGET_USER}" cp "${TARGET_HOME}/.oh-my-zsh/templates/zshrc.zsh-template" "${zshrc}"
  fi

  local plugins_line="plugins=(${plugins[*]})"
  if grep -q '^plugins=' "${zshrc}" >/dev/null 2>&1; then
    sed -i "s/^plugins=.*/${plugins_line}/" "${zshrc}"
  else
    printf '%s\n' "${plugins_line}" >>"${zshrc}"
  fi
  chown "${TARGET_USER}":"$(id -gn "${TARGET_USER}")" "${zshrc}"
}

install_powerlevel10k() {
  if [[ "${POWERLEVEL10K_ENABLED}" != "true" ]]; then
    log_info "Powerlevel10k no esta habilitado."
    return
  fi

  ensure_apt_packages git

  local theme_dir="${TARGET_HOME}/.oh-my-zsh/custom/themes/powerlevel10k"
  if [[ -d "${theme_dir}" ]]; then
    log_info "Powerlevel10k ya esta disponible en ${theme_dir}"
  else
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se clonaria Powerlevel10k en ${theme_dir}"
    else
      run_as_user "${TARGET_USER}" git clone --depth 1 https://github.com/romkatv/powerlevel10k.git "${theme_dir}"
    fi
  fi

  local zshrc="${TARGET_HOME}/.zshrc"
  if [[ "${DRY_RUN}" != "true" ]]; then
    if [[ ! -f "${zshrc}" ]]; then
      run_as_user "${TARGET_USER}" cp "${TARGET_HOME}/.oh-my-zsh/templates/zshrc.zsh-template" "${zshrc}"
    fi
    if ! grep -q 'ZSH_THEME=' "${zshrc}" >/dev/null 2>&1; then
      printf 'ZSH_THEME="powerlevel10k/powerlevel10k"\n' >>"${zshrc}"
    else
      sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "${zshrc}"
    fi
    if [[ "${POWERLEVEL10K_INSTANT}" == "true" ]] && ! grep -q 'p10k-instant-prompt' "${zshrc}" >/dev/null 2>&1; then
      cat <<'EOF' >>"${zshrc}"
# Configuracion de Powerlevel10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi
EOF
    fi
    chown "${TARGET_USER}":"$(id -gn "${TARGET_USER}")" "${zshrc}"
  else
    log_info "(dry-run) Se estableceria ZSH_THEME=powerlevel10k/powerlevel10k"
    if [[ "${POWERLEVEL10K_INSTANT}" == "true" ]]; then
      log_info "(dry-run) Se agregaria bloque de instant prompt"
    fi
  fi

  local p10k_config_source="${REPO_ROOT}/${POWERLEVEL10K_CONFIG}"
  local p10k_config_target="${TARGET_HOME}/.p10k.zsh"
  if [[ -n "${POWERLEVEL10K_CONFIG}" && -f "${p10k_config_source}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se copiaria ${p10k_config_source} a ${p10k_config_target}"
    else
      install -o "${TARGET_USER}" -g "$(id -gn "${TARGET_USER}")" -m 0644 "${p10k_config_source}" "${p10k_config_target}"
    fi
  else
    log_warn "No se encontro archivo de configuracion powerlevel10k en ${p10k_config_source}"
  fi
}

install_nerd_fonts() {
  local fonts=()
  local font_count="${NERD_FONT_COUNT:-0}"
  local idx=0
  while (( idx < font_count )); do
    local var_name="NERD_FONT_${idx}"
    local font_name="${!var_name:-}"
    font_name="${font_name//$'\r'/}"
    [[ -n "${font_name}" ]] && fonts+=("${font_name}")
    ((idx++))
  done

  if ((${#fonts[@]} == 0)); then
    log_info "No se solicitaron Nerd Fonts adicionales."
    return
  fi

  ensure_apt_packages curl unzip fontconfig

  local fonts_dir="/usr/local/share/fonts/nerd-fonts"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se instalarian las fuentes Nerd: ${fonts[*]}"
    return
  fi

  mkdir -p "${fonts_dir}"

  for font in "${fonts[@]}"; do
    case "${font}" in
      "MesloLGS NF")
        for variant in "Regular" "Bold" "Italic" "Bold Italic"; do
          local filename="MesloLGS NF ${variant}.ttf"
          local target_file="${fonts_dir}/${filename}"
          if [[ -f "${target_file}" ]]; then
            log_info "La fuente ${filename} ya existe."
            continue
          fi
          local encoded_variant="${variant// /%20}"
          local url="https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20${encoded_variant}.ttf"
          log_info "Descargando fuente ${filename}"
          curl -fsSL -o "${target_file}" "${url}"
        done
        ;;
      *)
        log_warn "Fuente Nerd no soportada automaticamente: ${font}"
        ;;
    esac
  done

  run_cmd "Actualizando cache de fuentes" fc-cache -f
}

configure_fontconfig() {
  if [[ "${NERD_FONTS_SET}" != "true" ]]; then
    return
  fi

  local config_dir="${TARGET_HOME}/.config/fontconfig/conf.d"
  local target_group
  target_group="$(id -gn "${TARGET_USER}")"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se configuraria MesloLGS NF como fuente monospace por defecto."
    return
  fi

  install -d -o "${TARGET_USER}" -g "${target_group}" "${config_dir}"
  cat <<'EOF' | install -o "${TARGET_USER}" -g "${target_group}" -m 0644 /dev/stdin "${config_dir}/99-debian-plasma-rice-meslo.conf"
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>monospace</family>
    <prefer>
      <family>MesloLGS NF</family>
    </prefer>
  </alias>
</fontconfig>
EOF
}

main() {
  module_parse_args "$@"
  module_setup_logging
  module_start

  load_shell_config

  install_zsh
  set_default_shell
  install_ohmyzsh
  configure_plugins
  install_powerlevel10k
  install_nerd_fonts
  configure_fontconfig

  module_finish
}

main "$@"
