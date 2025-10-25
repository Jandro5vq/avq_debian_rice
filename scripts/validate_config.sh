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
