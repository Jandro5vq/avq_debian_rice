#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="system"

# shellcheck source=../common.sh
source "${MODULE_DIR}/../common.sh"

enable_contrib_nonfree() {
  local sources_file="/etc/apt/sources.list"
  local temp_file

  if [[ ! -f "${sources_file}" ]]; then
    log_warn "No se encontro ${sources_file}, se omitira habilitar repositorios."
    return
  fi

  if grep -Eq 'non-free-firmware' "${sources_file}"; then
    log_info "Los componentes contrib/non-free ya estan presentes."
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se agregarian componentes contrib/non-free al repositorio principal."
    return
  fi

  temp_file="$(mktemp)"
  python3 - "${sources_file}" "${temp_file}" <<'PY'
import sys

source = sys.argv[1]
target = sys.argv[2]

extras = ["contrib", "non-free", "non-free-firmware"]
changed = False

with open(source, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

def normalize(words):
    existing = set(words)
    for item in extras:
        if item not in existing:
            words.append(item)
    return words

result = []
for raw in lines:
    stripped = raw.strip()
    if stripped.startswith("deb "):
        parts = raw.split()
        if len(parts) >= 4:
            head = parts[:3]
            comps = parts[3:]
            new_comps = normalize(comps)
            if comps != new_comps:
                changed = True
            result.append(" ".join(head + new_comps) + "\n")
        else:
            result.append(raw)
    else:
        result.append(raw)

with open(target, "w", encoding="utf-8") as fh:
    fh.writelines(result)

if changed:
    print("changed")
PY

  if cmp -s "${sources_file}" "${temp_file}"; then
    rm -f "${temp_file}"
    log_info "Los componentes requeridos ya estaban presentes."
  else
    mv "${temp_file}" "${sources_file}"
    log_info "Se habilitaron componentes contrib/non-free/non-free-firmware."
  fi
}

install_plasma_stack() {
  local install_sddm="$1"

  apt_candidate_available() {
    local pkg="$1"
    local candidate
    candidate=$(apt-cache policy "${pkg}" 2>/dev/null | awk '/Candidate:/ {print $2}')
    [[ -n "${candidate}" && "${candidate}" != "(none)" ]]
  }

  local packages=("plasma-desktop" "kde-config-gtk-style")

  if apt_candidate_available "plasma-workspace-wayland"; then
    packages+=("plasma-workspace-wayland")
  else
    log_warn "plasma-workspace-wayland no esta disponible; se utilizara plasma-workspace."
    packages+=("plasma-workspace")
  fi

  if [[ "${install_sddm}" == "true" ]]; then
    packages+=("sddm" "sddm-theme-debian-breeze")
  fi

  ensure_apt_packages "${packages[@]}"
}

install_fonts() {
  local -a fonts=()
  local font_name

  while IFS= read -r font_name; do
    font_name="${font_name//$'\r'/}"
    [[ -n "${font_name}" ]] && fonts+=("${font_name}")
  done < <(config_get_list "${CONFIG_JSON}" "system.fonts")

  if ((${#fonts[@]} > 0)); then
    ensure_apt_packages "${fonts[@]}"
  else
    log_info "No se declararon fuentes adicionales en la configuracion."
  fi
}

perform_upgrade() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se actualizarian los indices y paquetes del sistema."
    return
  fi

  run_cmd "Actualizando indices APT" apt-get update -y
  run_cmd "Actualizando paquetes APT" DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

main() {
  module_parse_args "$@"
  module_setup_logging
  module_start

  local enable_repos install_plasma install_sddm perform_full_upgrade

  enable_repos="$(config_get_bool "${CONFIG_JSON}" "system.enable_contrib_nonfree")"
  install_plasma="$(config_get_bool "${CONFIG_JSON}" "system.desktop_environment.plasma")"
  install_sddm="$(config_get_bool "${CONFIG_JSON}" "system.desktop_environment.sddm")"
  perform_full_upgrade="$(config_get_bool "${CONFIG_JSON}" "system.upgrade")"

  if [[ "${enable_repos}" == "true" ]]; then
    enable_contrib_nonfree
  else
    log_info "Se omite habilitar repositorios contrib/non-free segun configuracion."
  fi

  if [[ "${install_plasma}" == "true" ]]; then
    install_plasma_stack "${install_sddm}"
  else
    log_info "Se omite instalacion de Plasma segun configuracion."
  fi

  install_fonts

  if [[ "${perform_full_upgrade}" == "true" ]]; then
    perform_upgrade
  else
    log_info "Se omite apt upgrade segun configuracion."
  fi

  module_finish
}

main "$@"
