#!/usr/bin/env bash
# Funciones auxiliares compartidas por el runner y los modulos.
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '[ERROR] Este script solo debe ser utilizado mediante "source".\n' >&2
  exit 1
fi

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*"
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Se requieren privilegios de superusuario. Ejecute con sudo."
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

apt_candidate_exists() {
  local pkg="$1"
  local candidate
  candidate=$(apt-cache policy "${pkg}" 2>/dev/null | awk '/Candidate:/ {print $2}')
  [[ -n "${candidate}" && "${candidate}" != "(none)" ]]
}

ensure_download_tool() {
  if command_exists curl || command_exists wget; then
    return
  fi

  local attempted="false"
  if apt_candidate_exists curl; then
    ensure_apt_packages curl ca-certificates
    attempted="true"
  fi

  if ! command_exists curl && apt_candidate_exists wget; then
    ensure_apt_packages wget ca-certificates
    attempted="true"
  fi

  if ! command_exists curl && ! command_exists wget && [[ "${attempted}" != "true" ]]; then
    log_warn "No hay herramientas curl/wget en repos; se utilizara Python para descargas."
  fi
}

run_cmd() {
  local description="$1"
  shift
  local -a cmd=("$@")

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run) ${description}: ${cmd[*]}"
    return 0
  fi

  log_info "${description}: ${cmd[*]}"
  if ! env "${cmd[@]}"; then
    log_error "Fallo al ejecutar el comando anterior."
    return 1
  fi
}

run_cmd_silently() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    return 0
  fi
  "$@" >/dev/null 2>&1
}

ensure_apt_packages() {
  local packages_to_install=()
  local pkg

  for pkg in "$@"; do
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
      log_info "El paquete ${pkg} ya esta instalado."
    elif ! apt_candidate_exists "${pkg}"; then
      log_warn "El paquete ${pkg} no tiene candidato disponible; se omitira."
    else
      packages_to_install+=("${pkg}")
    fi
  done

  if ((${#packages_to_install[@]} == 0)); then
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run) Se instalarian los paquetes: ${packages_to_install[*]}"
    return 0
  fi

  log_info "Instalando paquetes APT: ${packages_to_install[*]}"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages_to_install[@]}"
}

download_deb_if_needed() {
  local url="$1"
  local dest="$2"
  local description="${3:-Paquete .deb externo}"

  if [[ -f "${dest}" ]]; then
    log_info "El paquete ${description} ya fue descargado."
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run) Se descargaria ${description} desde ${url}"
    return 0
  fi

  mkdir -p "$(dirname "${dest}")"
  ensure_download_tool

  log_info "Descargando ${description} desde ${url}"
  local success="false"

  if command_exists curl; then
    log_info "Descarga con curl"
    if curl -fsSL -o "${dest}" "${url}"; then
      success="true"
    else
      log_warn "curl no pudo descargar ${description}; se intentara con wget o Python."
    fi
  fi

  if [[ "${success}" != "true" && command_exists wget ]]; then
    log_info "Descarga con wget"
    if wget -qO "${dest}" "${url}"; then
      success="true"
    else
      log_warn "wget no pudo descargar ${description}; se intentara con Python."
    fi
  fi

  if [[ "${success}" != "true" ]]; then
    log_info "Descarga con Python"
    if ! python3 - "${dest}" "${url}" <<'PY'
import sys
import urllib.request

dest, url = sys.argv[1:3]
urllib.request.urlretrieve(url, dest)
PY
    then
      log_error "No se pudo descargar ${description}."
      return 1
    fi
    success="true"
  fi

  if [[ "${success}" != "true" || ! -s "${dest}" ]]; then
    log_error "La descarga de ${description} fallo o el archivo esta vacio."
    return 1
  fi
}

install_deb_package() {
  local deb_path="$1"
  local package_name="$2"

  if dpkg -s "${package_name}" >/dev/null 2>&1; then
    log_info "El paquete ${package_name} ya esta instalado."
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run) Se instalaria ${package_name} desde ${deb_path}"
    return 0
  fi

  log_info "Instalando ${package_name} desde ${deb_path}"
  apt-get install -y "${deb_path}"
}

# ...
ensure_apt_repository() {
  local repo_file="$1"
  local repo_definition="$2"
  local keyring_url="$3"
  local keyring_path="$4"

  if [[ -f "${repo_file}" ]]; then
    log_info "El repositorio ${repo_file} ya existe."
  else
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
      log_info "(dry-run) Se crearia el repositorio ${repo_file}"
    else
      log_info "Creando repositorio en ${repo_file}"
      printf '%s\n' "${repo_definition}" >"${repo_file}"
    fi
  fi

  if [[ -n "${keyring_url}" ]]; then
    if [[ -f "${keyring_path}" ]]; then
      log_info "El keyring ${keyring_path} ya existe."
    else
      if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "(dry-run) Se descargaria keyring desde ${keyring_url}"
      else
        log_info "Descargando keyring para repositorio personalizado."
        ensure_download_tool
        download_deb_if_needed "${keyring_url}" "${keyring_path}" "keyring"
        chmod 644 "${keyring_path}"
      fi
    fi
  fi
}

ensure_flatpak_remote() {
  local name="$1"
  local url="$2"

  if flatpak remote-info "${name}" >/dev/null 2>&1; then
    log_info "El remoto Flatpak ${name} ya existe."
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run) Se añadiria remoto Flatpak ${name} desde ${url}"
    return 0
  fi

  log_info "Añadiendo remoto Flatpak ${name}"
  flatpak remote-add --if-not-exists "${name}" "${url}"
}

ensure_symlink() {
  local source="$1"
  local target="$2"

  if [[ -L "${target}" && "$(readlink -f "${target}")" == "$(readlink -f "${source}")" ]]; then
    log_info "El enlace simbolico ${target} ya apunta a ${source}."
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run) Se enlazaria ${target} -> ${source}"
    return 0
  fi

  log_info "Creando enlace simbolico ${target} -> ${source}"
  mkdir -p "$(dirname "${target}")"
  ln -sf "${source}" "${target}"
}

copy_if_different() {
  local source="$1"
  local target="$2"

  if [[ -f "${target}" ]]; then
    local source_hash target_hash
    source_hash=$(sha256sum "${source}" | awk '{print $1}')
    target_hash=$(sha256sum "${target}" | awk '{print $1}')
    if [[ "${source_hash}" == "${target_hash}" ]]; then
      log_info "El archivo de destino ${target} ya coincide con el origen."
      return 0
    fi
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run) Se copiaria ${source} a ${target}"
    return 0
  fi

  log_info "Copiando ${source} a ${target}"
  mkdir -p "$(dirname "${target}")"
  cp -f "${source}" "${target}"
}

ensure_flatpak_app() {
  local app_id="$1"

  if flatpak info "${app_id}" >/dev/null 2>&1; then
    log_info "El Flatpak ${app_id} ya esta instalado."
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run) Se instalaria Flatpak ${app_id}"
    return 0
  fi

  log_info "Instalando Flatpak ${app_id}"
  flatpak install -y "${app_id}"
}

ensure_config_line() {
  local file_path="$1"
  local line="$2"

  if [[ -f "${file_path}" ]] && grep -Fxq "${line}" "${file_path}"; then
    log_info "La linea requerida ya existe en ${file_path}"
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run) Se añadiria linea en ${file_path}: ${line}"
    return 0
  fi

  log_info "Añadiendo linea a ${file_path}"
  mkdir -p "$(dirname "${file_path}")"
  printf '%s\n' "${line}" >>"${file_path}"
}

json_query() {
  local json_path="$1"
  local query="$2"

  if [[ ! -f "${json_path}" ]]; then
    log_error "Archivo de configuracion ${json_path} no disponible."
    return 1
  fi

  python3 - "${json_path}" "${query}" <<'PY'
import json
import sys

config_path = sys.argv[1]
query = sys.argv[2]

with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)

current = data
if query:
    for part in query.split('.'):
        if isinstance(current, dict) and part in current:
            current = current[part]
        else:
            current = None
            break

json.dump(current, sys.stdout)
PY
}

config_get_bool() {
  local json_path="$1"
  local query="$2"
  local default="${3:-false}"

  python3 - "${json_path}" "${query}" "${default}" <<'PY'
import json
import sys

config_path = sys.argv[1]
query = sys.argv[2]
default_raw = sys.argv[3].lower()

with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)

def normalize(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on")
    return False

current = data
if query:
    for part in query.split('.'):
        if isinstance(current, dict):
            current = current.get(part)
        else:
            current = None
            break

if current is None:
    current = default_raw in ("1", "true")

print("true" if normalize(current) else "false")
PY
}

config_get_list() {
  local json_path="$1"
  local query="$2"

  python3 - "${json_path}" "${query}" <<'PY'
import json
import sys

config_path = sys.argv[1]
query = sys.argv[2]

with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)

current = data
if query:
    for part in query.split('.'):
        if isinstance(current, dict):
            current = current.get(part)
        else:
            current = None
            break

if isinstance(current, list):
    for item in current:
        if isinstance(item, (dict, list)):
            sys.stdout.write(json.dumps(item))
        else:
            sys.stdout.write(str(item))
        sys.stdout.write("\n")
PY
}

run_as_user() {
  local user="$1"
  shift

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run) Ejecutaria como ${user}: $*"
    return 0
  fi

  if [[ "${user}" == "root" ]]; then
    "$@"
  else
    runuser -u "${user}" -- "$@"
  fi
}
