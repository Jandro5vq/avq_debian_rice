#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="apps"

# shellcheck source=../common.sh
source "${MODULE_DIR}/../common.sh"

declare -A FLATPAK_IDS=(
  [slack]="com.slack.Slack"
  [notepadpp]="com.notepad_plus_plus.NotepadPlusPlus"
  [spotify]="com.spotify.Client"
  [dbeaver-ce]="io.dbeaver.DBeaverCommunity"
  [android-studio]="com.google.AndroidStudio"
  [postman]="com.getpostman.Postman"
)

enumerate_apps() {
  python3 - "${CONFIG_JSON}" <<'PY'
import json
import sys

config_path = sys.argv[1]
with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)

apps_cfg = data.get("apps", {})
remotes = apps_cfg.get("flatpak", {}).get("remotes", [])
for remote in remotes:
    name = remote.get("name")
    url = remote.get("url")
    if name and url:
        print(f"REMOTE::{name}::{url}")

for entry in apps_cfg.get("list", []):
    name = entry.get("name")
    source = entry.get("source")
    auto_update = entry.get("auto_update", False)
    download_url = entry.get("download_url", "")
    if name and source:
        print(f"APP::{name}::{source}::{str(auto_update).lower()}::{download_url}")
PY
}

ensure_flatpak_base() {
  ensure_apt_packages flatpak
}

setup_brave_repository() {
  ensure_apt_packages curl apt-transport-https gpg
  local keyring="/usr/share/keyrings/brave-browser-archive-keyring.gpg"
  local repo_file="/etc/apt/sources.list.d/brave-browser-release.list"
  local arch
  arch="$(dpkg --print-architecture)"
  ensure_apt_repository "${repo_file}" "deb [signed-by=${keyring} arch=${arch}] https://brave-browser-apt-release.s3.brave.com/ stable main" "https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg" "${keyring}"
}

setup_vscode_repository() {
  ensure_apt_packages curl gpg apt-transport-https
  local keyring="/usr/share/keyrings/packages.microsoft.gpg"
  local repo_file="/etc/apt/sources.list.d/vscode.list"
  local arch
  arch="$(dpkg --print-architecture)"

  if [[ ! -f "${keyring}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se generaria el keyring de Microsoft en ${keyring}"
    else
      log_info "Generando keyring de Microsoft."
      curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor >"${keyring}"
      chmod 644 "${keyring}"
    fi
  else
    log_info "El keyring de Microsoft ya existe."
  fi

  if [[ ! -f "${repo_file}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se crearia el repositorio de VSCode en ${repo_file}"
    else
      printf 'deb [arch=%s signed-by=%s] https://packages.microsoft.com/repos/code stable main\n' "${arch}" "${keyring}" >"${repo_file}"
    fi
  else
    log_info "El repositorio de VSCode ya existe."
  fi
}

install_repo_app() {
  local name="$1"

  case "${name}" in
    brave)
      setup_brave_repository
      ensure_apt_packages brave-browser
      ;;
    vscode)
      setup_vscode_repository
      ensure_apt_packages apt-transport-https
      ensure_apt_packages code
      ;;
    *)
      log_warn "Aplicacion con repositorio oficial no reconocida: ${name}"
      ;;
  esac
}

install_apt_app() {
  local name="$1"

  ensure_apt_packages "${name}"
}

install_deb_app() {
  local name="$1"
  local download_url="$2"

  local work_dir
  work_dir="$(get_workdir)"

  case "${name}" in
    smartgit)
      local arch
      arch="$(dpkg --print-architecture)"
      if [[ "${arch}" != "amd64" ]]; then
        log_warn "SmartGit solo se automatiza para amd64."
        return
      fi
      local url="${download_url:-https://www.syntevo.com/downloads/smartgit/smartgit-linux-amd64.deb}"
      local deb_path="${work_dir}/smartgit-linux-amd64.deb"
      download_deb_if_needed "${url}" "${deb_path}" "SmartGit"
      install_deb_package "${deb_path}" "smartgit"
      ;;
    *)
      log_warn "No se implemento instalacion deb para ${name}"
      ;;
  esac
}

install_flatpak_app_from_map() {
  local name="$1"
  local app_id="${FLATPAK_IDS[${name}]:-}"

  if [[ -z "${app_id}" ]]; then
    log_warn "No se conoce el ID de Flatpak para ${name}"
    return
  fi

  ensure_flatpak_app "${app_id}"
}

install_manual_app() {
  local name="$1"
  local download_url="$2"

  case "${name}" in
    lazydocker)
      if command_exists lazydocker; then
        log_info "Lazydocker ya esta instalado."
        return
      fi

      ensure_apt_packages tar
      local arch_label
      case "$(dpkg --print-architecture)" in
        amd64)
          arch_label="x86_64"
          ;;
        arm64)
          arch_label="arm64"
          ;;
        *)
          log_warn "Arquitectura no soportada para lazydocker."
          return
          ;;
      esac

      local work_dir
      work_dir="$(mktemp -d)"
      local tarball="${work_dir}/lazydocker.tar.gz"
      local default_url="https://github.com/jesseduffield/lazydocker/releases/latest/download/lazydocker_${arch_label}.tar.gz"
      local url="${download_url:-$default_url}"
      if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "(dry-run) Se descargaria lazydocker desde ${url}"
        rm -rf "${work_dir}"
        return
      fi
      if download_file "${url}" "${tarball}" "lazydocker"; then
        tar -xf "${tarball}" -C "${work_dir}"
        install -m 0755 "${work_dir}/lazydocker" /usr/local/bin/lazydocker
      else
        log_warn "No se pudo obtener lazydocker desde ${url}; se omitira."
      fi
      rm -rf "${work_dir}"
      ;;
    *)
      log_warn "Aplicacion manual no implementada: ${name}"
      ;;
  esac
}

process_app_entry() {
  local name="$1"
  local source="$2"
  local auto_update="$3"
  local download_url="$4"

  case "${source}" in
    repo)
      install_repo_app "${name}"
      ;;
    apt)
      install_apt_app "${name}"
      ;;
    deb)
      install_deb_app "${name}" "${download_url}"
      ;;
    flatpak)
      install_flatpak_app_from_map "${name}"
      ;;
    manual)
      install_manual_app "${name}" "${download_url}"
      ;;
    *)
      log_warn "Fuente de instalacion no soportada: ${source} para ${name}"
      ;;
  esac
}

run_post_updates() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se ejecutaria apt upgrade"
    return
  fi

  run_cmd "Ejecutando apt upgrade" DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  if command_exists flatpak; then
    run_cmd "Actualizando Flatpak" flatpak update -y
  fi
}

main() {
  module_parse_args "$@"
  module_setup_logging
  module_start

  ensure_apt_packages curl
  ensure_flatpak_base
  local flatpak_available="true"
  if ! command_exists flatpak; then
    log_warn "Flatpak no esta disponible; se omitiran remotos y aplicaciones Flatpak."
    flatpak_available="false"
  fi

  while IFS='::' read -r kind arg1 arg2 arg3 arg4; do
    case "${kind}" in
      REMOTE)
        if [[ "${flatpak_available}" == "true" ]]; then
          ensure_flatpak_remote "${arg1}" "${arg2}"
        else
          log_warn "Se omite remoto Flatpak ${arg1} por falta de soporte."
        fi
        ;;
      APP)
        if [[ "${arg2}" == "flatpak" && "${flatpak_available}" != "true" ]]; then
          log_warn "Se omite instalacion Flatpak de ${arg1} por falta de soporte."
        else
          process_app_entry "${arg1}" "${arg2}" "${arg3}" "${arg4}"
        fi
        ;;
    esac
  done < <(enumerate_apps)

  run_post_updates

  module_finish
}

main "$@"

