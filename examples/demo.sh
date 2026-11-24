#!/usr/bin/env bash
# demo.sh — recorrido completo (alta, auditoría, baja) para el README.
# SOLO en el contenedor de pruebas: make demo. Crea y borra usuarios reales.

set -euo pipefail

if [[ "${UOA_IN_CONTAINER:-}" != "1" ]]; then
  echo "ABORTADO: la demo crea usuarios reales y solo corre en el contenedor (make demo)." >&2
  exit 64
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
cp config/policy.conf.example /tmp/policy.conf
NO_COLOR=1
export NO_COLOR

# step <comando> — muestra el comando tal cual, lo ejecuta y anota su código de salida.
step() {
  printf '\n$ %s\n' "$1"
  local rc=0
  bash -c "$1" 2>&1 || rc=$?
  printf '(código de salida: %d)\n' "$rc"
}

section() { printf '\n\n=== %s ===\n' "$1"; }

ONBOARD="scripts/onboard-users.sh --csv examples/users.csv --config /tmp/policy.conf"
OFFBOARD="scripts/offboard-users.sh --config /tmp/policy.conf"
AUDIT="scripts/audit-users.sh --csv examples/users.csv --config /tmp/policy.conf"

section "1. Simulación (modo por defecto): no cambia nada"
step "$ONBOARD"

section "2. Alta real con --apply"
step "$ONBOARD --apply"

section "3. Segunda ejecución: idempotente, no cambia nada"
step "$ONBOARD --apply"

section "4. Informe de contraseñas (solo root); contraseñas ocultadas aquí"
step "ls -ld /var/lib/user-onboarding"
step "ls -l /var/lib/user-onboarding | tail -n +2 | awk '{print \$1, \$3, \$4, \$NF}'"
step "sed -E '2,\$ s/^([^,]+),[^,]+,/\\1,********,/' /var/lib/user-onboarding/*.csv"

section "5. Política aplicada a una cuenta"
step "id ana.ruiz"
step "chage -l ana.ruiz"

section "6. Auditoría limpia"
step "$AUDIT"

section "7. Desvíos: cuenta ajena al CSV, cuenta bloqueada y grupo cambiado"
useradd -m intruso
echo 'intruso:Prueba-123-xyz' | chpasswd
usermod -L lucia.mora
usermod -aG sysadmin pablo.rey
step "$AUDIT"

section "8. Baja: simulación y ejecución (lucia.mora)"
step "$OFFBOARD --user lucia.mora"
step "$OFFBOARD --user lucia.mora --apply"
step "$OFFBOARD --user lucia.mora --apply"

section "9. Baja con eliminación explícita (pablo.rey)"
step "$OFFBOARD --user pablo.rey --apply --delete-home"
step "ls -l /var/backups/offboarding | tail -n +2 | awk '{print \$1, \$3, \$4, \$NF}'"
step "getent passwd pablo.rey || echo 'pablo.rey ya no existe'"
