#!/usr/bin/env bash
# lib/common.sh — funciones compartidas por los scripts de onboarding.
# Se carga con: source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# No se ejecuta directamente.

# Librería: las constantes se usan desde los scripts que la cargan.
# shellcheck disable=SC2034

# Códigos de salida estándar (compatibles con los plugins de Nagios).
readonly EXIT_OK=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2
readonly EXIT_UNKNOWN=3
readonly EXIT_USAGE=64

# Colores solo si la salida es una terminal y NO_COLOR no está definido.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  readonly C_RED=$'\033[31m' C_YELLOW=$'\033[33m' C_GREEN=$'\033[32m' C_RESET=$'\033[0m'
else
  readonly C_RED="" C_YELLOW="" C_GREEN="" C_RESET=""
fi

# log <nivel> <mensaje...> — escribe en stderr con marca de hora.
log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
}

log_info() { log INFO "$*"; }
log_warn() { log "${C_YELLOW}WARN${C_RESET}" "$*"; }
log_error() { log "${C_RED}ERROR${C_RESET}" "$*"; }

# die <mensaje> [código] — error fatal: muestra el mensaje y sale.
die() {
  log_error "$1"
  exit "${2:-1}"
}

# require_cmd <comando...> — aborta (código 3) si falta alguna dependencia.
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Falta el comando requerido: $cmd" "$EXIT_UNKNOWN"
  done
}

# is_uint <valor> — verdadero si es un entero no negativo.
is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# require_root <acción> — las acciones reales (--apply) y la lectura de shadow exigen root.
require_root() {
  ((EUID == 0)) || die "$1 requiere ejecutarse como root." "$EXIT_UNKNOWN"
}

# Prefijo de las líneas de acción en stdout: "[DRY-RUN]" o "[HECHO]".
ACTION_PREFIX="[DRY-RUN]"

# set_mode <apply|dry-run> — fija el prefijo de las líneas de acción.
set_mode() {
  if [[ "$1" == "apply" ]]; then ACTION_PREFIX="[HECHO]"; else ACTION_PREFIX="[DRY-RUN]"; fi
}

# emit <mensaje...> — línea de acción en stdout (lo que se haría / se ha hecho).
emit() {
  printf '%s %s\n' "$ACTION_PREFIX" "$*"
}

# emit_skip <mensaje...> — nada que hacer (ya estaba así); mismo prefijo en ambos modos.
emit_skip() {
  printf '[SIN CAMBIOS] %s\n' "$*"
}

# today_days — días transcurridos desde 1970-01-01 (misma unidad que /etc/shadow).
today_days() {
  echo $(($(date +%s) / 86400))
}

# trim <cadena> — quita espacios al principio y al final.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# in_list <elemento> <lista separada por espacios> — verdadero si está en la lista.
in_list() {
  local item="$1" candidate
  for candidate in $2; do
    [[ "$candidate" == "$item" ]] && return 0
  done
  return 1
}

# home_is_safe <ruta> — la ruta está estrictamente dentro de HOME_BASE.
# Impide archivar o borrar "/", "/root" o cualquier directorio fuera de la política.
home_is_safe() {
  local home="$1"
  [[ "$home" == "${HOME_BASE}"/* && "$home" != *".."* && "$home" != "${HOME_BASE}/" ]]
}
