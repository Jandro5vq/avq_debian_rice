# debian-plasma-rice

Repositorio declarativo para provisionar Debian base con Plasma KDE, apariencia tipo Zorin y stack de desarrollo.

## Caracteristicas
- Ejecucion modular e idempotente a partir de YAML.
- Compatibilidad con Debian 12 y Debian testing.
- Plasma + SDDM con tema Orchis, iconos Papirus y cursor Bibata.
- Tabby y Kitty configurados con Meslo Nerd Font.
- Shell Zsh con Oh-My-Zsh y Powerlevel10k.
- Apps de productividad via APT, repos oficiales y Flatpak.
- Docker Engine y plugin compose listos para uso.
- Dotfiles coherentes para zsh, tabby, kitty y fastfetch.
- MOTD ASCII y preset de fastfetch minimalista.

## Estructura
```
debian-plasma-rice/
|-- runner.sh
|-- config/
|   |-- base.yml
|   |-- profiles/
|   |   |-- laptop.yml
|   |   \-- workstation.yml
|   \-- secrets.example.yml
|-- schemas/config.schema.json
|-- scripts/
|   |-- helpers.sh
|   |-- facts.sh
|   \-- validate_config.sh
|-- modules/
|   |-- system/ ... post/
|-- dotfiles/
|-- assets/
\-- README.md
```

## Requisitos previos
- Debian limpio sin entorno grafico.
- Acceso sudo.
- Conexion a internet para descargar paquetes.

## Puesta en marcha
1. Clonar el repositorio y entrar al directorio.
2. Revisar `config/base.yml` y, si aplica, los overrides en `config/profiles/`.
3. Opcional: copiar `config/secrets.example.yml` a `config/secrets.yml` y completar valores privados.
4. Ejecutar:
   ```bash
   sudo bash runner.sh --profile laptop
   ```

### Flags disponibles
- `--dry-run` ejecuta en modo simulacion.
- `--only modules=a,b` limita la ejecucion a modulos concretos.
- `--skip modules=x` omite modulos especificos.
- `--profile laptop|workstation` selecciona el perfil de configuracion.

## Modulos incluidos
- `system`: repositorios contrib/non-free, Plasma, SDDM y fuentes.
- `theming`: tema Orchis, Papirus azul, cursor Bibata, Kvantum y wallpaper.
- `terminal`: instalacion de Tabby/Kitty y registro en update-alternatives.
- `shell`: Zsh, Oh-My-Zsh, Powerlevel10k y Nerd Fonts.
- `apps`: repos oficiales, APT, deb externos, Flatpak y actualizaciones.
- `dev`: Docker Engine, plugin compose y pertenencia al grupo docker.
- `dotfiles`: copia idempotente de configuraciones declaradas.
- `telemetry`: fastfetch, preset minimal y MOTD ASCII.
- `post`: limpieza final, habilitacion de SDDM y reinicio de servicios claves.

## Desarrollo y depuracion
- Ejecutar modulos individuales con `sudo bash modules/<nombre>/module.sh --config <ruta_json> --profile <perfil>`.
- Usar `--dry-run` para validar cambios sin aplicar modificaciones.
- Consultar logs en `/var/log/debian-plasma-rice/` para diagnostico.

## Licencia
Este proyecto se distribuye bajo licencia MIT (agregar archivo LICENSE si se requiere).
