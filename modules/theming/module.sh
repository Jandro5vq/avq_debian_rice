#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="theming"

# shellcheck source=../common.sh
source "${MODULE_DIR}/../common.sh"

install_orchis_kde() {
  local theme_dir="/usr/share/plasma/desktoptheme/Orchis-Dark"

  if [[ -d "${theme_dir}" ]]; then
    log_info "El tema Orchis KDE ya esta instalado en ${theme_dir}."
    return
  fi

  ensure_apt_packages git

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se clonaria el repositorio de Orchis KDE e instalaria en /usr/share."
    return
  fi

  local work_dir
  work_dir="$(mktemp -d)"

  run_cmd "Clonando tema Orchis KDE" git clone --depth 1 https://github.com/vinceliuice/Orchis-kde "${work_dir}/Orchis-kde"
  run_cmd "Instalando tema Orchis KDE" bash "${work_dir}/Orchis-kde/install.sh" -d /usr
  rm -rf "${work_dir}"
}

configure_papirus_icons() {
  local icon_theme="$1"
  local folder_color="$2"

  ensure_apt_packages papirus-icon-theme

  if command_exists papirus-folders; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "(dry-run) Se configurarian las carpetas de Papirus a color ${folder_color}."
    else
      run_cmd "Aplicando color ${folder_color} a Papirus" papirus-folders -C "${folder_color}" --theme "${icon_theme}"
    fi
  else
    log_warn "No se encontro papirus-folders, no se ajustara el color de carpetas."
  fi
}

install_cursor_theme() {
  local cursor_theme="$1"

  ensure_apt_packages bibata-cursor-theme

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se configuraria update-alternatives para cursor ${cursor_theme}"
    return
  fi

  if update-alternatives --query x-cursor-theme >/dev/null 2>&1; then
    CURRENT_CURSOR="$(update-alternatives --query x-cursor-theme | awk -F': ' '/Value/ {print $2}')"
    if [[ "${CURRENT_CURSOR}" == "${cursor_theme}" ]]; then
      log_info "El cursor ${cursor_theme} ya esta establecido como predeterminado."
    else
      run_cmd "Actualizando cursor predeterminado" update-alternatives --set x-cursor-theme "${cursor_theme}"
    fi
  else
    run_cmd "Configurando cursor predeterminado" update-alternatives --install /usr/share/icons/default/index.theme x-cursor-theme "/usr/share/icons/${cursor_theme}/index.theme" 100
  fi
}

copy_wallpaper() {
  local wallpaper_path="$1"
  local target_dir="/usr/share/backgrounds/debian-plasma-rice"
  local file_name

  if [[ ! -f "${wallpaper_path}" ]]; then
    log_warn "El wallpaper ${wallpaper_path} no existe, se omite la copia."
    return
  fi

  file_name="$(basename "${wallpaper_path}")"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se copiaria el wallpaper a ${target_dir}/${file_name}"
    return
  fi

  mkdir -p "${target_dir}"
  copy_if_different "${wallpaper_path}" "${target_dir}/${file_name}"
}

configure_user_theme() {
  local theme_name="$1"
  local color_scheme="$2"
  local icon_theme="$3"
  local cursor_theme="$4"
  local kvantum_theme="$5"
  local wallpaper_path="$6"

  local target_group
  target_group="$(id -gn "${TARGET_USER}")"

  if ! command_exists kwriteconfig5; then
    log_warn "kwriteconfig5 no se encuentra disponible; no se aplicaran ajustes de usuario."
    return
  fi

  local kdeglobals="${TARGET_HOME}/.config/kdeglobals"
  local kcminputrc="${TARGET_HOME}/.config/kcminputrc"
  local kvantum_dir="${TARGET_HOME}/.config/Kvantum"
  local kvantum_cfg="${kvantum_dir}/kvantum.kvconfig"
  local autostart_dir="${TARGET_HOME}/.config/autostart-scripts"
  local autostart_script="${autostart_dir}/debian-plasma-rice-wallpaper.sh"
  local wallpaper_target="/usr/share/backgrounds/debian-plasma-rice/$(basename "${wallpaper_path}")"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se configuraria KDE para usar tema ${theme_name}, esquema ${color_scheme}, iconos ${icon_theme}, cursor ${cursor_theme}."
  else
    install -d -o "${TARGET_USER}" -g "${target_group}" "$(dirname "${kdeglobals}")"
    install -d -o "${TARGET_USER}" -g "${target_group}" "$(dirname "${kcminputrc}")"
    install -d -o "${TARGET_USER}" -g "${target_group}" "${kvantum_dir}"
  fi

  run_as_user "${TARGET_USER}" kwriteconfig5 --file kdeglobals --group General --key ColorScheme "${color_scheme}"
  run_as_user "${TARGET_USER}" kwriteconfig5 --file kdeglobals --group General --key Name "${theme_name}"
  run_as_user "${TARGET_USER}" kwriteconfig5 --file kdeglobals --group Icons --key Theme "${icon_theme}"
  run_as_user "${TARGET_USER}" kwriteconfig5 --file kdeglobals --group KDE --key widgetStyle "kvantum"

  run_as_user "${TARGET_USER}" kwriteconfig5 --file kcminputrc --group Mouse --key cursorTheme "${cursor_theme}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se escribiria configuracion de Kvantum en ${kvantum_cfg}"
  else
    cat <<EOF | install -o "${TARGET_USER}" -g "${target_group}" -m 0644 /dev/stdin "${kvantum_cfg}"
[General]
theme=${kvantum_theme}
EOF
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "(dry-run) Se crearia script de autostart para aplicar wallpaper en ${autostart_script}"
  else
    install -d -o "${TARGET_USER}" -g "${target_group}" "${autostart_dir}"
    cat <<EOF | install -o "${TARGET_USER}" -g "${target_group}" -m 0755 /dev/stdin "${autostart_script}"
#!/usr/bin/env bash
# Script generado por debian-plasma-rice para fijar wallpaper.
WALLPAPER="${wallpaper_target}"
MARKER="\${HOME}/.config/.debian-plasma-wallpaper.done"
if [[ -f "\${MARKER}" ]]; then
  exit 0
fi
if command -v plasma-apply-wallpaperimage >/dev/null 2>&1; then
  plasma-apply-wallpaperimage "\${WALLPAPER}" && touch "\${MARKER}"
fi
EOF
  fi
}

main() {
  module_parse_args "$@"
  module_setup_logging
  module_start

  local style plasma_theme color_scheme kvantum_theme icon_theme icon_color cursor_theme wallpaper_path

  style="$(config_get_value "${CONFIG_JSON}" "theming.style")"
  plasma_theme="$(config_get_value "${CONFIG_JSON}" "theming.plasma_theme")"
  color_scheme="$(config_get_value "${CONFIG_JSON}" "theming.color_scheme")"
  kvantum_theme="$(config_get_value "${CONFIG_JSON}" "theming.kvantum_theme")"
  icon_theme="$(config_get_value "${CONFIG_JSON}" "theming.icons.name")"
  icon_color="$(config_get_value "${CONFIG_JSON}" "theming.icons.folders_color")"
  cursor_theme="$(config_get_value "${CONFIG_JSON}" "theming.cursor")"
  wallpaper_path="$(config_get_value "${CONFIG_JSON}" "theming.wallpaper")"

  log_info "Estilo solicitado: ${style}"

  install_orchis_kde
  configure_papirus_icons "${icon_theme}" "${icon_color:-blue}"
  install_cursor_theme "${cursor_theme}"

  copy_wallpaper "${REPO_ROOT}/${wallpaper_path}"

  configure_user_theme "${plasma_theme}" "${color_scheme}" "${icon_theme}" "${cursor_theme}" "${kvantum_theme}" "${REPO_ROOT}/${wallpaper_path}"

  module_finish
}

main "$@"
