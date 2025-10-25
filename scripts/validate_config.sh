#!/usr/bin/env bash
# Valida la configuracion YAML contra el esquema JSON y genera una version fusionada.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./helpers.sh
source "${SCRIPT_DIR}/helpers.sh"

usage() {
  cat <<'EOF'
Uso: validate_config.sh --config <ruta_yaml> --schema <ruta_schema> [--profile <perfil>] [--output <ruta_json>]
Valida y fusiona la configuracion declarativa antes de ejecutar los modulos.
EOF
}

CONFIG_PATH=""
SCHEMA_PATH=""
PROFILE_OVERRIDE=""
OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --schema)
      SCHEMA_PATH="$2"
      shift 2
      ;;
    --profile)
      PROFILE_OVERRIDE="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      log_error "Parametro no reconocido: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${CONFIG_PATH}" || -z "${SCHEMA_PATH}" ]]; then
  log_error "Debe especificar --config y --schema."
  usage
  exit 1
fi

if [[ ! -f "${CONFIG_PATH}" ]]; then
  log_error "El archivo de configuracion ${CONFIG_PATH} no existe."
  exit 1
fi

if [[ ! -f "${SCHEMA_PATH}" ]]; then
  log_error "El archivo de esquema ${SCHEMA_PATH} no existe."
  exit 1
fi

ensure_apt_packages python3 python3-yaml python3-jsonschema

download_get_pip() {
  local dest="$1"
  local url="$2"

  if command_exists curl; then
    run_cmd "Descargando instalador get-pip" curl -fsSL -o "${dest}" "${url}"
    return
  fi

  if command_exists wget; then
    run_cmd "Descargando instalador get-pip" wget -qO "${dest}" "${url}"
    return
  fi

  run_cmd "Descargando instalador get-pip con Python" python3 - "${dest}" "${url}" <<'PY'
import sys
import urllib.request

dest, url = sys.argv[1:3]
urllib.request.urlretrieve(url, dest)
PY
}

pip_install_module() {
  local package="$1"
  if ! run_cmd "Instalando modulo Python ${package}" PIP_BREAK_SYSTEM_PACKAGES=1 python3 -m pip install --upgrade --break-system-packages "${package}"; then
    run_cmd "Instalando modulo Python ${package} (modo usuario)" python3 -m pip install --user --upgrade "${package}"
  fi
}

ensure_python_modules() {
  local -a missing_modules=()
  local module package
  for mapping in "yaml:PyYAML" "jsonschema:jsonschema"; do
    module="${mapping%%:*}"
    package="${mapping##*:}"
    if ! python3 -c "import ${module}" >/dev/null 2>&1; then
      missing_modules+=("${package}")
    fi
  done

  if ((${#missing_modules[@]} == 0)); then
    return
  fi

  if ! command_exists pip3; then
    if apt_candidate_exists python3-pip; then
      ensure_apt_packages python3-pip
    fi
    if apt_candidate_exists curl; then
      ensure_apt_packages curl ca-certificates
    fi
    if apt_candidate_exists wget; then
      ensure_apt_packages wget ca-certificates
    fi
  fi

  if ! command_exists pip3; then
    local get_pip_script
    get_pip_script="$(mktemp)"
    download_get_pip "${get_pip_script}" "https://bootstrap.pypa.io/get-pip.py"
    run_cmd "Instalando pip mediante get-pip" PIP_BREAK_SYSTEM_PACKAGES=1 python3 "${get_pip_script}" --disable-pip-version-check
    rm -f "${get_pip_script}"
  fi

  for package in "${missing_modules[@]}"; do
    pip_install_module "${package}"
  done
}

ensure_python_modules

if [[ -z "${OUTPUT_PATH}" ]]; then
  OUTPUT_PATH="$(mktemp "${ROOT_DIR}/config_validated_XXXXXX.json")"
fi

export CONFIG_PATH SCHEMA_PATH PROFILE_OVERRIDE OUTPUT_PATH ROOT_DIR

MERGED_CONFIG_PATH="$(
python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError as exc:
    raise SystemExit(f"[ERROR] PyYAML no disponible: {exc}") from exc

try:
    import jsonschema
except ModuleNotFoundError as exc:
    raise SystemExit(f"[ERROR] jsonschema no disponible: {exc}") from exc


def deep_merge(base, override):
    if not isinstance(base, dict) or not isinstance(override, dict):
        return override
    result = dict(base)
    for key, value in override.items():
        if key in result:
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


config_path = Path(os.environ["CONFIG_PATH"])
schema_path = Path(os.environ["SCHEMA_PATH"])
profile_override = os.environ.get("PROFILE_OVERRIDE", "").strip()
root_dir = Path(os.environ["ROOT_DIR"])
output_path = Path(os.environ["OUTPUT_PATH"])

with config_path.open("r", encoding="utf-8") as fh:
    base_config = yaml.safe_load(fh) or {}

if not isinstance(base_config, dict):
    raise SystemExit("[ERROR] La configuracion base debe ser un objeto YAML.")

meta = base_config.get("meta", {})

active_profile = profile_override or meta.get("profile")
if not active_profile:
    raise SystemExit("[ERROR] No se definio un perfil activo. Use --profile o meta.profile.")

profile_file = root_dir / "config" / "profiles" / f"{active_profile}.yml"
if profile_file.exists():
    with profile_file.open("r", encoding="utf-8") as pfh:
        profile_config = yaml.safe_load(pfh) or {}
    merged_config = deep_merge(base_config, profile_config)
else:
    merged_config = base_config

merged_config.setdefault("meta", {})
merged_config["meta"]["profile"] = active_profile

with schema_path.open("r", encoding="utf-8") as sfh:
    schema = json.load(sfh)

jsonschema.validate(instance=merged_config, schema=schema)

with output_path.open("w", encoding="utf-8") as out_fh:
    json.dump(merged_config, out_fh, indent=2, ensure_ascii=False)
    out_fh.write("\n")

print(output_path)
PY
)"
MERGED_CONFIG_PATH="${MERGED_CONFIG_PATH//$'\r'/}"
MERGED_CONFIG_PATH="${MERGED_CONFIG_PATH//$'\n'/}"

log_info "Configuracion validada correctamente: ${MERGED_CONFIG_PATH}"
printf '%s\n' "${MERGED_CONFIG_PATH}"

