#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="dev"

# shellcheck source=../common.sh
source "${MODULE_DIR}/../common.sh"

load_dev_config() {
  eval "$(
    python3 - "${CONFIG_JSON}" <<'PY'
import json
import sys
from shlex import quote

config_path = sys.argv[1]
with open(config_path, encoding="utf-8") as fh:
    data = json.load(fh)

containers = data.get("dev", {}).get("containers", {})

def emit_str(key, value, fallback=""):
    if value is None:
        value = fallback
    print(f"{key}={quote(str(value))}")

def emit_bool(key, value, fallback=False):
    if value is None:
        value = fallback
    print(f"{key}={'true' if value else 'false'}")

emit_str("DEV_CONTAINER_ENGINE", containers.get("engine"), "")
emit_bool("DEV_ADD_USER_TO_GROUP", containers.get("add_user_to_group"), True)
emit_bool("DEV_COMPOSE_PLUGIN", containers.get("compose_plugin"), True)

github = data.get("github", {})
emit_bool("GITHUB_CONFIGURE", github.get("configure"), False)

user = github.get("user", {})
emit_str("GITHUB_USER_NAME", user.get("name"), "")
emit_str("GITHUB_USER_EMAIL", user.get("email"), "")

ssh_key = github.get("ssh_key", {})
emit_str("GITHUB_SSH_TYPE", ssh_key.get("type"), "ed25519")
emit_str("GITHUB_SSH_COMMENT", ssh_key.get("comment"), "")
emit_str("GITHUB_SSH_PASSPHRASE", ssh_key.get("passphrase"), "")
emit_bool("GITHUB_SSH_ADD_AGENT", ssh_key.get("add_to_agent"), True)

cli = github.get("cli", {})
emit_bool("GITHUB_INSTALL_GH", cli.get("install_gh"), True)
emit_str("GITHUB_AUTH_MODE", cli.get("auth"), "web")
emit_bool("GITHUB_UPLOAD_KEY", cli.get("upload_ssh_key"), False)
emit_str("GITHUB_CLI_TOKEN", cli.get("token"), "")
PY
  )"
}

setup_docker_repository() {
  ensure_apt_packages ca-certificates lsb-release
  local net_tools="false"
  if apt_candidate_exists curl; then
    ensure_apt_packages curl
    net_tools="true"
  fi
  if apt_candidate_exists gnupg; then
    ensure_apt_packages gnupg
    net_tools="true"
  fi

  if [[ "${net_tools}" != "true" ]]; then
    log_warn "curl/gpg no estan disponibles en repos; se omitira la configuracion del repositorio Docker."
    return 1
  fi

  local keyring="/etc/apt/keyrings/docker.gpg"
  local repo_file="/etc/apt/sources.list.d/docker.list"
  local arch
  arch="$(dpkg --print-architecture)"
  local codename
  codename="$(lsb_release -cs)"

  if [[ ! -d "/etc/apt/keyrings" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se crearia /etc/apt/keyrings"
    else
      mkdir -p /etc/apt/keyrings
      chmod 755 /etc/apt/keyrings
    fi
  fi

  if [[ ! -f "${keyring}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se generaria el keyring de Docker en ${keyring}"
    else
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o "${keyring}"
      chmod 644 "${keyring}"
    fi
  fi

  if [[ ! -f "${repo_file}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se crearia repositorio Docker en ${repo_file}"
    else
      printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/debian %s stable\n' "${arch}" "${keyring}" "${codename}" >"${repo_file}"
    fi
  fi
}

install_docker_engine() {
  if ! setup_docker_repository; then
    log_warn "No se pudo preparar el repositorio de Docker; se omite instalacion."
    return
  fi

  local packages=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
  )

  if [[ "${DEV_COMPOSE_PLUGIN}" == "true" ]]; then
    packages+=("docker-compose-plugin")
  fi

  ensure_apt_packages "${packages[@]}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se habilitaria y arrancaria el servicio docker"
  else
    run_cmd "Habilitando servicio docker" systemctl enable docker
    run_cmd "Iniciando servicio docker" systemctl start docker
  fi
}

add_user_to_docker_group() {
  if [[ "${DEV_ADD_USER_TO_GROUP}" != "true" ]]; then
    return
  fi

  if [[ "${TARGET_USER}" == "root" ]]; then
    log_warn "Se omite agregar root al grupo docker."
    return
  fi

  if id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -Fxq "docker"; then
    log_info "El usuario ${TARGET_USER} ya pertenece al grupo docker."
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se agregaria ${TARGET_USER} al grupo docker."
  else
    run_cmd "Agregando usuario ${TARGET_USER} al grupo docker" usermod -aG docker "${TARGET_USER}"
  fi
}

configure_git_identity() {
  if [[ -z "${GITHUB_USER_NAME}" && -z "${GITHUB_USER_EMAIL}" ]]; then
    return
  fi

  ensure_apt_packages git

  if [[ -n "${GITHUB_USER_NAME}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se configuraria git user.name=${GITHUB_USER_NAME}"
    else
      run_as_user "${TARGET_USER}" git config --global user.name "${GITHUB_USER_NAME}"
    fi
  fi

  if [[ -n "${GITHUB_USER_EMAIL}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se configuraria git user.email=${GITHUB_USER_EMAIL}"
    else
      run_as_user "${TARGET_USER}" git config --global user.email "${GITHUB_USER_EMAIL}"
    fi
  fi
}

install_github_cli() {
  if [[ "${GITHUB_INSTALL_GH}" != "true" ]]; then
    return
  fi

  if command_exists gh; then
    log_info "GitHub CLI ya esta instalado."
    return
  fi

  ensure_apt_packages curl apt-transport-https gpg

  local keyring="/usr/share/keyrings/githubcli-archive-keyring.gpg"
  local repo_file="/etc/apt/sources.list.d/github-cli.list"
  local arch
  arch="$(dpkg --print-architecture)"

  if [[ ! -f "${keyring}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se escribiria keyring para GitHub CLI"
    else
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o "${keyring}"
      chmod 644 "${keyring}"
    fi
  fi

  if [[ ! -f "${repo_file}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se registraria repositorio de GitHub CLI"
    else
      printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' "${arch}" "${keyring}" >"${repo_file}"
    fi
  fi

  ensure_apt_packages gh
}

generate_github_ssh_key() {
  local key_type="${GITHUB_SSH_TYPE:-ed25519}"
  local ssh_dir="${TARGET_HOME}/.ssh"
  local key_name="id_${key_type}"
  local key_path="${ssh_dir}/${key_name}"
  local pub_path="${key_path}.pub"
  local target_group
  target_group="$(id -gn "${TARGET_USER}")"
  local comment="${GITHUB_SSH_COMMENT:-${TARGET_USER}@$(hostname)}"

  ensure_apt_packages openssh-client

  if [[ -f "${key_path}" ]]; then
    log_info "La llave SSH ${key_path} ya existe."
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se generaria llave SSH ${key_name}"
    return
  fi

  install -d -m 0700 -o "${TARGET_USER}" -g "${target_group}" "${ssh_dir}"
  local passphrase="${GITHUB_SSH_PASSPHRASE}" 
  run_as_user "${TARGET_USER}" ssh-keygen -t "${key_type}" -C "${comment}" -N "${passphrase}" -f "${key_path}"
  chmod 0600 "${key_path}"
  chmod 0644 "${pub_path}"
}

configure_ssh_agent_snippet() {
  if [[ "${GITHUB_SSH_ADD_AGENT}" != "true" ]]; then
    return
  fi

  local zshrc="${TARGET_HOME}/.zshrc"
  local key_type="${GITHUB_SSH_TYPE:-ed25519}"
  local key_path="${TARGET_HOME}/.ssh/id_${key_type}"
  local marker="# debian-plasma-rice ssh-agent"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se agregaria snippet de ssh-agent en ${zshrc}"
    return
  fi

  if [[ ! -f "${zshrc}" ]]; then
    run_as_user "${TARGET_USER}" touch "${zshrc}"
  fi

  if ! grep -q "${marker}" "${zshrc}" >/dev/null 2>&1; then
    cat <<EOF | install -o "${TARGET_USER}" -g "$(id -gn "${TARGET_USER}")" -m 0644 /dev/stdin "${zshrc}.github.tmp"
${marker}
if [[ -z "\${SSH_AUTH_SOCK}" ]]; then
  eval "\$(ssh-agent -s)" >/dev/null 2>&1
  ssh-add "${key_path}" >/dev/null 2>&1
fi
EOF
    cat "${zshrc}" >>"${zshrc}.github.tmp"
    mv "${zshrc}.github.tmp" "${zshrc}"
  fi
}

authenticate_github_cli() {
  if [[ "${GITHUB_INSTALL_GH}" != "true" ]]; then
    return
  fi

  if ! command_exists gh; then
    log_warn "GitHub CLI no esta disponible; se omite autenticacion."
    return
  fi

  if run_as_user "${TARGET_USER}" gh auth status >/dev/null 2>&1; then
    log_info "GitHub CLI ya esta autenticado."
    return
  fi

  case "${GITHUB_AUTH_MODE}" in
    token)
      local token="${GITHUB_CLI_TOKEN}"
      if [[ -z "${token}" && -n "${GITHUB_TOKEN}" ]]; then
        token="${GITHUB_TOKEN}"
      fi
      if [[ -z "${token}" ]]; then
        log_warn "No se proporciono token para GitHub CLI; autenticacion omitida."
        return
      fi
      if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "(dry-run) Se autenticaria GitHub CLI con token"
      else
        log_info "Autenticando GitHub CLI mediante token."
        run_as_user "${TARGET_USER}" env GITHUB_AUTH_TOKEN="${token}" bash -lc 'printf "%s\n" "${GITHUB_AUTH_TOKEN}" | gh auth login --hostname github.com --git-protocol ssh --with-token --scopes "repo,read:org,admin:public_key"'
      fi
      ;;
    web)
      log_warn "Autenticacion via web requiere intervencion manual: ejecutar 'gh auth login --web --git-protocol ssh' como ${TARGET_USER}."
      ;;
    *)
      log_warn "Modo de autenticacion de GitHub no soportado: ${GITHUB_AUTH_MODE}"
      ;;
  esac
}

upload_github_ssh_key() {
  if [[ "${GITHUB_UPLOAD_KEY}" != "true" ]]; then
    return
  fi

  if ! command_exists gh; then
    log_warn "GitHub CLI no esta disponible para subir la llave."
    return
  fi

  if ! run_as_user "${TARGET_USER}" gh auth status >/dev/null 2>&1; then
    log_warn "GitHub CLI no esta autenticado; no se subira la llave."
    return
  fi

  local key_type="${GITHUB_SSH_TYPE:-ed25519}"
  local pub_path="${TARGET_HOME}/.ssh/id_${key_type}.pub"
  if [[ ! -f "${pub_path}" ]]; then
    log_warn "No se encontro la llave publica ${pub_path} para subirla a GitHub."
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se subiria la llave SSH a GitHub"
    return
  fi

  run_as_user "${TARGET_USER}" gh ssh-key add "${pub_path}" --title "${GITHUB_SSH_COMMENT:-debian-plasma-rice}" >/dev/null 2>&1 || log_warn "No se pudo subir la llave SSH a GitHub (puede que ya exista)."
}

handle_github_configuration() {
  if [[ "${GITHUB_CONFIGURE}" != "true" ]]; then
    return
  fi

  configure_git_identity
  install_github_cli
  generate_github_ssh_key
  configure_ssh_agent_snippet
  authenticate_github_cli
  upload_github_ssh_key
}

main() {
  module_parse_args "$@"
  module_setup_logging
  module_start

  load_dev_config

  if [[ "${DEV_CONTAINER_ENGINE}" == "docker" ]]; then
    install_docker_engine
    add_user_to_docker_group
  else
    log_warn "Motor de contenedores no soportado: ${DEV_CONTAINER_ENGINE}"
  fi

  handle_github_configuration

  module_finish
}

main "$@"
