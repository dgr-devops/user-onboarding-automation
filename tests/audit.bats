#!/usr/bin/env bats
# Tests de scripts/audit-users.sh (se ejecutan como root dentro del contenedor).

load test_helper

setup() {
  setup_env
  onboard_example
}
teardown() { cleanup_env; }

audit() {
  run "$AUDIT" --csv "$EXAMPLE_CSV" --config "$POLICY"
}

@test "sin --csv sale con 64" {
  run "$AUDIT"
  [ "$status" -eq 64 ]
}

@test "cuentas recién creadas: conformes, con aviso informativo de cambio pendiente" {
  audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO"*"cambio de contraseña pendiente"* ]]
  [[ "$output" == *"conformes=5 warning=0 critical=0"* ]]
}

@test "usuario del CSV que no existe: CRITICAL (2)" {
  userdel -r lucia.mora
  audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"CRITICAL"*"lucia.mora"*"falta"* ]]
}

@test "cuenta activa fuera del CSV: CRITICAL (2)" {
  add_active_user intruso
  audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"CRITICAL"*"intruso"*"fuera del CSV y con la cuenta activa"* ]]
}

@test "cuenta fuera del CSV pero bloqueada: WARNING (1)" {
  useradd -m exempleado
  usermod -L exempleado
  audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING"*"exempleado"*"baja pendiente"* ]]
}

@test "cuenta del CSV bloqueada: WARNING (1)" {
  usermod -L ana.ruiz
  audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING"*"ana.ruiz"*"cuenta bloqueada"* ]]
}

@test "shell distinta a la del CSV: WARNING (1)" {
  usermod -s /bin/sh ana.ruiz
  audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"ana.ruiz"*"shell /bin/sh (CSV: /bin/bash)"* ]]
}

@test "grupo añadido a mano: WARNING (1)" {
  usermod -aG sysadmin ana.ruiz
  audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"ana.ruiz"*"grupos 'developers,sysadmin' (CSV: 'developers')"* ]]
}

@test "contraseña más vieja que PASS_MAX_DAYS: WARNING (1)" {
  chage -d 2020-01-01 ana.ruiz
  audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"ana.ruiz"*"contraseña de"*"máximo 90"* ]]
}

@test "cuenta caducada: WARNING (1)" {
  chage -E 2020-01-01 ana.ruiz
  audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"ana.ruiz"*"cuenta caducada el 2020-01-01"* ]]
}

@test "política de envejecimiento distinta a la vigente: WARNING (1)" {
  chage -M 365 ana.ruiz
  audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"ana.ruiz"*"PASS_MAX_DAYS=365"* ]]
}

@test "con un WARNING y un CRITICAL gana el más grave (2)" {
  usermod -L ana.ruiz
  add_active_user intruso
  audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"warning=1 critical=1"* ]]
}

@test "la auditoría no modifica nada" {
  useradd -m intruso
  local before
  before="$(snapshot_accounts)"
  audit
  [ "$(snapshot_accounts)" = "$before" ]
}

@test "sin root sale con 3 (no puede leer /etc/shadow)" {
  run runuser -u nobody -- "$AUDIT" --csv "$EXAMPLE_CSV" --config "$POLICY"
  [ "$status" -eq 3 ]
}

@test "un CSV con usuarios inválidos no se audita (2)" {
  make_csv bad.csv <<'EOF'
username,full_name,department,groups,shell
Mal.Usuario,Nombre,Soporte,support,/bin/bash
EOF
  run "$AUDIT" --csv "$CSV_FILE" --config "$POLICY"
  [ "$status" -eq 2 ]
}
