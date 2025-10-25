#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="dotfiles"

# shellcheck source=../common.sh
source "${MODULE_DIR}/../common.sh"

enumerate_mappings() {
  python3 - "${CONFIG_JSON}" <<'PY'
import json
import sys

config_path = sys.argv[1]
with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)

dotfiles = data.get("dotfiles", {})
mode = dotfiles.get("mode", "direct")
repo = dotfiles.get("repo", "IN-REPO")

print(f"MODE::{mode}")
print(f"REPO::{repo}")

for mapping in dotfiles.get("mapping", []):
    source = mapping.get("source")
    target = mapping.get("target")
    if source and target:
        print(f"MAP::{source}::{target}")
PY
}

prepare_target_path() {
  local path="$1"
  if [[ "${path}" == "~"* ]]; then
    path="${TARGET_HOME}${path:1}"
  fi
  printf '%s\n' "${path}"
}

copy_file() {
  local source="$1"
  local target="$2"
  local target_dir
  target_dir="$(dirname "${target}")"
  local target_group
  target_group="$(id -gn "${TARGET_USER}")"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se copiaria archivo ${source} a ${target}"
    return
  fi

  install -d -o "${TARGET_USER}" -g "${target_group}" "${target_dir}"
  install -o "${TARGET_USER}" -g "${target_group}" -m 0644 "${source}" "${target}"
}

copy_directory() {
  local source="$1"
  local target="$2"
  local target_group
  target_group="$(id -gn "${TARGET_USER}")"

  ensure_apt_packages rsync

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se sincronizaria directorio ${source} hacia ${target}"
    return
  fi

  install -d -o "${TARGET_USER}" -g "${target_group}" "${target}"
  run_cmd "Sincronizando ${source} en ${target}" rsync -a --delete "${source}/" "${target}/"
  chown -R "${TARGET_USER}:${target_group}" "${target}"
}

process_mapping() {
  local source_rel="$1"
  local target_spec="$2"

  local source_abs="${REPO_ROOT}/${source_rel}"
  local target_abs
  target_abs="$(prepare_target_path "${target_spec}")"

  if [[ ! -e "${source_abs}" ]]; then
    log_warn "El recurso de dotfiles ${source_abs} no existe."
    return
  fi

  if [[ -d "${source_abs}" ]]; then
    copy_directory "${source_abs}" "${target_abs}"
  else
    copy_file "${source_abs}" "${target_abs}"
  fi
}

main() {
  module_parse_args "$@"
  module_setup_logging
  module_start

  local mode=""
  local repo_location=""

  while IFS='::' read -r kind arg1 arg2; do
    case "${kind}" in
      MODE)
        mode="${arg1}"
        ;;
      REPO)
        repo_location="${arg1}"
        ;;
      MAP)
        if [[ "${mode}" == "direct" && "${repo_location}" == "IN-REPO" ]]; then
          process_mapping "${arg1}" "${arg2}"
        else
          log_warn "Modo de dotfiles no soportado: ${mode} con repo ${repo_location}"
        fi
        ;;
    esac
  done < <(enumerate_mappings)

  module_finish
}

main "$@"
