#!/usr/bin/env bash
# Orquestador principal de debian-plasma-rice.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./scripts/helpers.sh
source "${REPO_ROOT}/scripts/helpers.sh"
# shellcheck source=./scripts/facts.sh
source "${REPO_ROOT}/scripts/facts.sh"

require_root

CLI_DRY_RUN="false"
PROFILE_OVERRIDE=""
declare -a ONLY_MODULES=()
declare -a SKIP_MODULES=()

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"

if [[ -z "${TARGET_HOME}" ]]; then
  log_error "No se pudo determinar el directorio home para ${TARGET_USER}."
  exit 1
fi

usage() {
  cat <<'EOF'
Uso: sudo ./runner.sh [--dry-run] [--profile <perfil>] [--only modules=a,b] [--skip modules=x,y]

--dry-run           Ejecuta en modo simulacion sin aplicar cambios.
--profile           Selecciona un perfil declarado en config/profiles.
--only modules=...  Limita la ejecucion a modulos concretos (separados por coma).
--skip modules=...  Omite los modulos indicados.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      CLI_DRY_RUN="true"
      shift
      ;;
    --profile)
      PROFILE_OVERRIDE="$2"
      shift 2
      ;;
    --only)
      if [[ $# -lt 2 ]]; then
        log_error "Falta argumento para --only."
        usage
        exit 1
      fi
      if [[ "$2" != modules=* ]]; then
        log_error "Formato invalido para --only. Use --only modules=a,b"
        exit 1
      fi
      IFS=',' read -r -a ONLY_MODULES <<<"${2#modules=}"
      shift 2
      ;;
    --skip)
      if [[ $# -lt 2 ]]; then
        log_error "Falta argumento para --skip."
        usage
        exit 1
      fi
      if [[ "$2" != modules=* ]]; then
        log_error "Formato invalido para --skip. Use --skip modules=x,y"
        exit 1
      fi
      IFS=',' read -r -a SKIP_MODULES <<<"${2#modules=}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      log_error "Parametro desconocido: $1"
      usage
      exit 1
      ;;
  esac
done

# Normalizamos listas de modulos eliminando espacios y convirtiendo a minusculas.
normalize_modules() {
  local -n ref_array=$1
  for idx in "${!ref_array[@]}"; do
    local value="${ref_array[$idx]}"
    value="${value// /}"
    ref_array[$idx]="${value,,}"
  done
}

normalize_modules ONLY_MODULES
normalize_modules SKIP_MODULES

declare -a ALL_MODULES=(
  "system" "theming" "terminal" "shell" "apps" "dev" "dotfiles" "telemetry" "post"
)

declare -A MODULE_SET=()
for module in "${ALL_MODULES[@]}"; do
  MODULE_SET["${module}"]=1
done

validate_module_list() {
  local -n collection=$1
  local label="$2"
  for module in "${collection[@]}"; do
    if [[ -z "${MODULE_SET[${module}]:-}" ]]; then
      log_error "El modulo ${module} no es valido para ${label}."
      exit 1
    fi
  done
}

validate_module_list ONLY_MODULES "--only"
validate_module_list SKIP_MODULES "--skip"

LOG_DIR="/var/log/debian-plasma-rice"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/runner-$(date +%Y%m%d-%H%M%S).log"
touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"

# Reflejamos la salida tanto por pantalla como por archivo.
exec > >(tee -a "${LOG_FILE}") 2>&1

log_info "Iniciando debian-plasma-rice en $(hostname)"

CONFIG_PATH="${REPO_ROOT}/config/base.yml"
SCHEMA_PATH="${REPO_ROOT}/schemas/config.schema.json"
MERGED_CONFIG_PATH="$(mktemp "${REPO_ROOT}/config_validated_XXXXXX.json")"

VALIDATE_CMD=("${REPO_ROOT}/scripts/validate_config.sh" --config "${CONFIG_PATH}" --schema "${SCHEMA_PATH}" --output "${MERGED_CONFIG_PATH}")
if [[ -n "${PROFILE_OVERRIDE}" ]]; then
  VALIDATE_CMD+=(--profile "${PROFILE_OVERRIDE}")
fi

"${VALIDATE_CMD[@]}"

if [[ ! -f "${MERGED_CONFIG_PATH}" ]]; then
  log_error "No se pudo generar la configuracion validada."
  exit 1
fi

ACTIVE_PROFILE="$(
python3 - "${MERGED_CONFIG_PATH}" <<'PY'
import json
import sys

config_path = sys.argv[1]
with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("meta", {}).get("profile", ""))
PY
)"
ACTIVE_PROFILE="${ACTIVE_PROFILE//$'\r'/}"
ACTIVE_PROFILE="${ACTIVE_PROFILE//$'\n'/}"

if [[ -z "${ACTIVE_PROFILE}" ]]; then
  log_error "No fue posible determinar el perfil activo."
  exit 1
fi

CONFIG_DRY_RUN="$(
python3 - "${MERGED_CONFIG_PATH}" <<'PY'
import json
import sys

config_path = sys.argv[1]
with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)
print(str(data.get("meta", {}).get("dry_run", False)).lower())
PY
)"
CONFIG_DRY_RUN="${CONFIG_DRY_RUN//$'\r'/}"
CONFIG_DRY_RUN="${CONFIG_DRY_RUN//$'\n'/}"

DRY_RUN="false"
if [[ "${CLI_DRY_RUN}" == "true" || "${CONFIG_DRY_RUN}" == "true" ]]; then
  DRY_RUN="true"
fi

export DRY_RUN
export CONFIG_JSON_PATH="${MERGED_CONFIG_PATH}"
export REPO_ROOT
export LOG_DIR
export TARGET_USER
export TARGET_HOME

log_info "Perfil activo: ${ACTIVE_PROFILE}"
log_info "Modo dry-run: ${DRY_RUN}"

declare -a FINAL_MODULES=()
for module in "${ALL_MODULES[@]}"; do
  local_include="true"
  if ((${#ONLY_MODULES[@]} > 0)); then
    local_include="false"
    for item in "${ONLY_MODULES[@]}"; do
      if [[ "${item}" == "${module}" ]]; then
        local_include="true"
        break
      fi
    done
  fi

  if [[ "${local_include}" != "true" ]]; then
    continue
  fi

  for item in "${SKIP_MODULES[@]}"; do
    if [[ "${item}" == "${module}" ]]; then
      local_include="false"
      break
    fi
  done

  if [[ "${local_include}" == "true" ]]; then
    FINAL_MODULES+=("${module}")
  fi
done

if ((${#FINAL_MODULES[@]} == 0)); then
  log_warn "No se selecciono ningun modulo para ejecutar."
  exit 0
fi

log_info "Modulos a ejecutar: ${FINAL_MODULES[*]}"

for module in "${FINAL_MODULES[@]}"; do
  MODULE_SCRIPT="${REPO_ROOT}/modules/${module}/module.sh"
  if [[ ! -x "${MODULE_SCRIPT}" ]]; then
    log_error "El modulo ${module} no tiene script ejecutable en ${MODULE_SCRIPT}"
    exit 1
  fi

  log_info "Ejecutando modulo ${module}"
  MODULE_CMD=(
    "${MODULE_SCRIPT}"
    --config "${CONFIG_JSON_PATH}"
    --profile "${ACTIVE_PROFILE}"
    --log-dir "${LOG_DIR}"
    --target-user "${TARGET_USER}"
    --target-home "${TARGET_HOME}"
  )
  if [[ "${DRY_RUN}" == "true" ]]; then
    MODULE_CMD+=(--dry-run)
  fi
  "${MODULE_CMD[@]}"
done

log_info "Ejecucion completada. Revisa ${LOG_FILE} para mas detalles."
