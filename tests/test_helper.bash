#!/usr/bin/env bash
# tests/test_helper.bash — utilidades comunes de los tests bats.
# Uso en cada .bats:  load test_helper
#
# SEGURIDAD: estos tests crean y borran usuarios reales. Solo se ejecutan dentro del
# contenedor de pruebas (make test). Si falta la marca UOA_IN_CONTAINER abortan sin tocar nada.

# Variables y funciones se usan desde los ficheros .bats que cargan este helper.
# shellcheck disable=SC2034

if [[ "${UOA_IN_CONTAINER:-}" != "1" ]]; then
  echo "ABORTADO: estos tests modifican cuentas de usuario y solo corren en el contenedor (make test)." >&2
  exit 1
fi

PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
readonly PROJECT_ROOT
readonly ONBOARD="${PROJECT_ROOT}/scripts/onboard-users.sh"
readonly OFFBOARD="${PROJECT_ROOT}/scripts/offboard-users.sh"
readonly AUDIT="${PROJECT_ROOT}/scripts/audit-users.sh"
readonly EXAMPLE_CSV="${PROJECT_ROOT}/examples/users.csv"
readonly MANAGED_GROUPS=(developers sysadmin support)

# setup_env — directorio temporal y política de prueba con informes y archivos aislados.
setup_env() {
  TEST_TMP="$(mktemp -d)"
  chmod 755 "$TEST_TMP"
  POLICY="${TEST_TMP}/policy.conf"
  REPORT_DIR="${TEST_TMP}/reports"
  ARCHIVE_DIR="${TEST_TMP}/archive"
  sed -e "s|^REPORT_DIR=.*|REPORT_DIR=${REPORT_DIR}|" \
    -e "s|^ARCHIVE_DIR=.*|ARCHIVE_DIR=${ARCHIVE_DIR}|" \
    "${PROJECT_ROOT}/config/policy.conf.example" >"$POLICY"
  chmod 644 "$POLICY"
}

# cleanup_env — deja el contenedor como estaba: sin usuarios gestionados ni grupos de la política.
cleanup_env() {
  local user uid group
  while IFS=: read -r user _ uid _; do
    if ((uid >= 1000 && uid < 60000)); then userdel -r "$user" >/dev/null 2>&1 || true; fi
  done < <(getent passwd)
  while IFS=: read -r group _ gid _; do
    if ((gid >= 1000 && gid < 60000)); then groupdel "$group" >/dev/null 2>&1 || true; fi
  done < <(getent group)
  for group in "${MANAGED_GROUPS[@]}"; do
    groupdel "$group" >/dev/null 2>&1 || true
  done
  rm -rf "$TEST_TMP" /srv/extuser
  return 0
}

# make_csv <nombre> — escribe stdin como CSV de prueba y deja su ruta en CSV_FILE.
make_csv() {
  CSV_FILE="${TEST_TMP}/$1"
  cat >"$CSV_FILE"
  chmod 644 "$CSV_FILE"
}

# set_policy <CLAVE> <valor> — cambia un valor de la política de prueba.
set_policy() {
  sed -i "s|^$1=.*|$1=$2|" "$POLICY"
}

# snapshot_accounts — huella de passwd, shadow y group para comprobar que nada cambia.
snapshot_accounts() {
  sha256sum /etc/passwd /etc/shadow /etc/group | awk '{print $1}' | paste -sd,
}

# shadow_of <usuario> <campo> — campo de /etc/shadow (1=nombre ... 8=caducidad).
shadow_of() {
  getent shadow "$1" | cut -d: -f"$2"
}

# add_active_user <usuario> — cuenta ajena al CSV con contraseña (useradd a secas queda bloqueada).
add_active_user() {
  useradd -m "$1"
  printf '%s:%s\n' "$1" "Prueba-123-xyz" | chpasswd
}

# onboard_example — da de alta el CSV de ejemplo con la política de prueba.
onboard_example() {
  "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply >/dev/null 2>&1
}
