#!/usr/bin/env bash
# Funciones para obtener datos del sistema anfitrion.
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf '[ERROR] Este script debe ser utilizado mediante "source".\n' >&2
  exit 1
fi

detect_debian_major_version() {
  local version
  version=$(grep -oE 'VERSION_ID="[0-9]+"' /etc/os-release | cut -d'"' -f2 || echo "")
  printf '%s\n' "${version%%.*}"
}

detect_is_testing() {
  if grep -qi 'testing' /etc/os-release; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

detect_architecture() {
  dpkg --print-architecture
}

get_workdir() {
  local work_dir="/tmp/debian-plasma-rice"
  mkdir -p "${work_dir}"
  printf '%s\n' "${work_dir}"
}

