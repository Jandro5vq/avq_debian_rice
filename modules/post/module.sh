#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="post"

# shellcheck source=../common.sh
source "${MODULE_DIR}/../common.sh"

load_post_config() {
  eval "$(
    python3 - "${CONFIG_JSON}" <<'PY'
import json
import sys

config_path = sys.argv[1]
with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)

updates = data.get("updates", {})

auto_run = updates.get("auto_run_at_end", False)
print(f"POST_AUTO_UPDATES={'true' if auto_run else 'false'}")
PY
  )"
}

enable_sddm() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se habilitaria SDDM y el objetivo grafico."
    return
  fi

  if systemctl list-unit-files | grep -q "^sddm.service"; then
    run_cmd "Habilitando SDDM" systemctl enable sddm
    run_cmd "Habilitando inicio grafico" systemctl set-default graphical.target
  else
    log_warn "No se encontro sddm.service para habilitar."
  fi
}

restart_services() {
  local services=("sddm" "docker")

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se reiniciarian servicios: ${services[*]}"
    return
  fi

  for svc in "${services[@]}"; do
    if systemctl list-units --type=service --all | grep -q "${svc}.service"; then
      run_cmd "Reiniciando servicio ${svc}" systemctl restart "${svc}"
    fi
  done
}

run_cleanup() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se ejecutaria apt autoremove y autoclean."
    return
  fi

  run_cmd "Ejecutando apt autoremove" DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
  run_cmd "Ejecutando apt autoclean" apt-get autoclean -y
}

run_final_updates() {
  if [[ "${POST_AUTO_UPDATES}" != "true" ]]; then
    log_info "Las actualizaciones finales estan deshabilitadas."
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se ejecutarían apt update && apt upgrade finales."
    return
  fi

  run_cmd "Actualizando indices finales" apt-get update -y
  run_cmd "Actualizando paquetes finales" DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

main() {
  module_parse_args "$@"
  module_setup_logging
  module_start

  load_post_config
  run_final_updates
  run_cleanup
  enable_sddm
  restart_services

  module_finish
}

main "$@"

