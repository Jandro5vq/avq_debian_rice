#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="telemetry"

# shellcheck source=../common.sh
source "${MODULE_DIR}/../common.sh"

load_telemetry_config() {
  eval "$(
    python3 - "${CONFIG_JSON}" <<'PY'
import json
import sys
from shlex import quote

config_path = sys.argv[1]
with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)

fastfetch = data.get("telemetry", {}).get("fastfetch", {})
motd = fastfetch.get("motd", {})

def emit_str(key, value, fallback=""):
    if value is None:
        value = fallback
    print(f"{key}={quote(str(value))}")

def emit_bool(key, value, fallback=False):
    if value is None:
        value = fallback
    print(f"{key}={'true' if value else 'false'}")

emit_bool("FASTFETCH_ENABLED", fastfetch.get("enabled"), False)
emit_str("FASTFETCH_PRESET", fastfetch.get("preset"), "")
emit_str("FASTFETCH_ASCII_FILE", fastfetch.get("ascii_file"), "")
emit_bool("FASTFETCH_MOTD_ENABLED", motd.get("enabled"), False)
emit_str("FASTFETCH_MOTD_POSITION", motd.get("position"), "top")
PY
  )"
}

install_fastfetch() {
  if [[ "${FASTFETCH_ENABLED}" != "true" ]]; then
    log_info "Fastfetch no esta habilitado."
    return 1
  fi
  ensure_apt_packages fastfetch
  return 0
}

deploy_preset() {
  if [[ "${FASTFETCH_ENABLED}" != "true" ]]; then
    return
  fi

  local source="${REPO_ROOT}/${FASTFETCH_PRESET}"
  local target="${TARGET_HOME}/.config/fastfetch/config.jsonc"
  local target_group
  target_group="$(id -gn "${TARGET_USER}")"

  if [[ ! -f "${source}" ]]; then
    log_warn "El preset de fastfetch ${source} no existe."
    return
  fi

  if [[ -f "${target}" ]]; then
    log_info "Ya existe una configuracion de fastfetch en ${target}"
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se copiaria preset de fastfetch a ${target}"
    return
  fi

  install -d -o "${TARGET_USER}" -g "${target_group}" "$(dirname "${target}")"
  install -o "${TARGET_USER}" -g "${target_group}" -m 0644 "${source}" "${target}"
}

deploy_ascii_art() {
  if [[ "${FASTFETCH_ENABLED}" != "true" ]]; then
    return
  fi

  local source="${REPO_ROOT}/${FASTFETCH_ASCII_FILE}"
  local target_dir="/usr/share/fastfetch"
  local target="${target_dir}/ascii-avq.txt"

  if [[ ! -f "${source}" ]]; then
    log_warn "El archivo ASCII ${source} no existe."
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se copiaria ASCII art a ${target}"
    return
  fi

  mkdir -p "${target_dir}"
  copy_if_different "${source}" "${target}"
}

configure_motd() {
  if [[ "${FASTFETCH_MOTD_ENABLED}" != "true" ]]; then
    log_info "El MOTD personalizado esta desactivado."
    return
  fi

  if [[ "${FASTFETCH_MOTD_POSITION}" != "top" ]]; then
    log_warn "Solo se implementa posicion 'top' para el MOTD."
  fi

  local motd_script="/etc/profile.d/00-debian-plasma-rice-motd.sh"
  local ascii_path="/usr/share/fastfetch/ascii-avq.txt"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se instalaria MOTD en ${motd_script}"
    return
  fi

  cat <<'EOF' >"${motd_script}"
#!/usr/bin/env bash
# MOTD generado por debian-plasma-rice
ASCII_PATH="/usr/share/fastfetch/ascii-avq.txt"
if [[ -f "${ASCII_PATH}" ]]; then
  cat "${ASCII_PATH}"
fi
EOF
  chmod 0755 "${motd_script}"
}

main() {
  module_parse_args "$@"
  module_setup_logging
  module_start

  load_telemetry_config

  if install_fastfetch; then
    deploy_preset
    deploy_ascii_art
    configure_motd
  else
    log_warn "Fastfetch no se configurara por estar deshabilitado."
  fi

  module_finish
}

main "$@"
