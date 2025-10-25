#!/usr/bin/env bash
# Funciones compartidas por los modulos individuales.
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '[ERROR] Este script debe ser cargado mediante "source".\n' >&2
  exit 1
fi

# shellcheck source=../../scripts/helpers.sh
source "$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/helpers.sh"
# shellcheck source=../../scripts/facts.sh
source "$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/facts.sh"

MODULE_NAME="${MODULE_NAME:-unknown}"

module_parse_args() {
  CONFIG_JSON=""
  PROFILE_NAME=""
  MODULE_LOG_DIR=""
  MODULE_DRY_RUN="${DRY_RUN:-false}"
  TARGET_USER=""
  TARGET_HOME=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG_JSON="$2"
        shift 2
        ;;
      --profile)
        PROFILE_NAME="$2"
        shift 2
        ;;
      --log-dir)
        MODULE_LOG_DIR="$2"
        shift 2
        ;;
      --dry-run)
        MODULE_DRY_RUN="true"
        shift
        ;;
      --target-user)
        TARGET_USER="$2"
        shift 2
        ;;
      --target-home)
        TARGET_HOME="$2"
        shift 2
        ;;
      --help|-h)
        module_usage
        exit 0
        ;;
      *)
        log_error "Parametro no reconocido para ${MODULE_NAME}: $1"
        module_usage
        exit 1
        ;;
    esac
  done

  if [[ -z "${CONFIG_JSON}" || -z "${MODULE_LOG_DIR}" ]]; then
    log_error "Debe proporcionar --config y --log-dir para ${MODULE_NAME}."
    module_usage
    exit 1
  fi

  if [[ -z "${TARGET_USER}" ]]; then
    TARGET_USER="root"
  fi
  if [[ -z "${TARGET_HOME}" ]]; then
    TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
  fi

  if [[ ! -f "${CONFIG_JSON}" ]]; then
    log_error "El archivo de configuracion ${CONFIG_JSON} no existe."
    exit 1
  fi

  export DRY_RUN="${MODULE_DRY_RUN}"
}

module_setup_logging() {
  MODULE_LOG_FILE="${MODULE_LOG_DIR}/${MODULE_NAME}.log"
  touch "${MODULE_LOG_FILE}"
  chmod 640 "${MODULE_LOG_FILE}"
  exec > >(tee -a "${MODULE_LOG_FILE}") 2>&1
}

module_usage() {
  cat <<EOF
Uso: ${MODULE_NAME}/module.sh --config <ruta_json> --profile <perfil> --log-dir <ruta> [--dry-run] [--target-user <usuario>] [--target-home <ruta>]
EOF
}

module_start() {
  log_info "Iniciando modulo ${MODULE_NAME}"
}

module_finish() {
  log_info "Finalizo modulo ${MODULE_NAME}"
}
