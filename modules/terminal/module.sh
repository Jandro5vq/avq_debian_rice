#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="terminal"

# shellcheck source=../common.sh
source "${MODULE_DIR}/../common.sh"

load_terminal_config() {
  eval "$(
    python3 - "${CONFIG_JSON}" <<'PY'
import json
import sys
from shlex import quote

config_path = sys.argv[1]
with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)

terminal = data.get("terminal", {})
install = terminal.get("install", {})

def emit(key, value):
    if isinstance(value, bool):
        print(f"{key}={'true' if value else 'false'}")
    else:
        print(f"{key}={quote(value if value is not None else '')}")

emit("TERMINAL_DEFAULT", terminal.get("default", ""))

tabby = install.get("tabby", {})
emit("TABBY_ENABLED", tabby.get("enabled", False))
emit("TABBY_SOURCE", tabby.get("source", ""))
emit("TABBY_VERSION", tabby.get("version", "latest"))
emit("TABBY_SET_DEFAULT", tabby.get("set_as_default_x_terminal", False))

kitty = install.get("kitty", {})
emit("KITTY_ENABLED", kitty.get("enabled", False))
emit("KITTY_SOURCE", kitty.get("source", "apt"))
emit("KITTY_SET_DEFAULT", kitty.get("set_as_default_x_terminal", False))
PY
  )"
}

install_tabby() {
  if [[ "${TABBY_ENABLED}" != "true" ]]; then
    log_info "Tabby no esta habilitado en la configuracion."
    return
  fi

  if command_exists tabby; then
    log_info "Tabby ya se encuentra instalado."
    return
  fi

  if [[ "${TABBY_SOURCE}" != "deb" ]]; then
    log_warn "Fuente para Tabby no soportada: ${TABBY_SOURCE}"
    return
  fi

  local arch_label
  case "$(detect_architecture)" in
    amd64|x86_64)
      arch_label="x64"
      ;;
    arm64|aarch64)
      arch_label="arm64"
      ;;
    *)
      log_error "Arquitectura no soportada para Tabby."
      return
      ;;
  esac

  ensure_apt_packages curl

  local version_tag="${TABBY_VERSION}"
  local download_url
  if [[ -z "${version_tag}" || "${version_tag}" == "latest" ]]; then
    download_url="https://releases.tabby.sh/linux/${arch_label}/tabby-latest.deb"
  else
    download_url="https://github.com/Eugeny/tabby/releases/download/v${version_tag}/tabby-${version_tag}-linux-${arch_label}.deb"
  fi

  local work_dir
  work_dir="$(get_workdir)"
  local deb_path="${work_dir}/tabby-${arch_label}-${version_tag}.deb"

  download_deb_if_needed "${download_url}" "${deb_path}" "Tabby"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se instalaria Tabby desde ${deb_path}"
    return
  fi

  run_cmd "Instalando Tabby" apt-get install -y "${deb_path}"
}

install_kitty() {
  if [[ "${KITTY_ENABLED}" != "true" ]]; then
    log_info "Kitty no esta habilitado en la configuracion."
    return
  fi

  if command_exists kitty; then
    log_info "Kitty ya se encuentra instalado."
    return
  fi

  if [[ "${KITTY_SOURCE}" != "apt" ]]; then
    log_warn "Fuente para Kitty no soportada: ${KITTY_SOURCE}"
    return
  fi

  ensure_apt_packages kitty
}

register_terminal() {
  local binary_path="$1"
  local priority="$2"
  local name="$3"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se registraria ${name} como alternativa x-terminal-emulator"
    return
  fi

  if [[ ! -x "${binary_path}" ]]; then
    log_warn "No se encontro ejecutable en ${binary_path}, no se registra ${name}."
    return
  fi

  update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator "${binary_path}" "${priority}"
}

set_default_terminal() {
  local preferred="$1"
  local binary_path="$2"

  if [[ -z "${preferred}" ]]; then
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se estableceria ${preferred} como terminal predeterminado."
    return
  fi

  if [[ ! -x "${binary_path}" ]]; then
    log_warn "No se puede establecer ${preferred}, el ejecutable ${binary_path} no existe."
    return
  fi

  update-alternatives --set x-terminal-emulator "${binary_path}"
}

main() {
  module_parse_args "$@"
  module_setup_logging
  module_start

  load_terminal_config

  install_tabby
  install_kitty

  local tabby_bin="/usr/bin/tabby"
  local kitty_bin="/usr/bin/kitty"

  if command_exists tabby; then
    register_terminal "${tabby_bin}" 70 "Tabby"
  fi
  if command_exists kitty; then
    register_terminal "${kitty_bin}" 60 "Kitty"
  fi

  if [[ "${TABBY_SET_DEFAULT}" == "true" ]]; then
    set_default_terminal "tabby" "${tabby_bin}"
  elif [[ "${KITTY_SET_DEFAULT}" == "true" ]]; then
    set_default_terminal "kitty" "${kitty_bin}"
  elif [[ -n "${TERMINAL_DEFAULT}" ]]; then
    case "${TERMINAL_DEFAULT}" in
      tabby)
        set_default_terminal "tabby" "${tabby_bin}"
        ;;
      kitty)
        set_default_terminal "kitty" "${kitty_bin}"
        ;;
      *)
        log_warn "Terminal predeterminado ${TERMINAL_DEFAULT} no reconocido."
        ;;
    esac
  fi

  module_finish
}

main "$@"
