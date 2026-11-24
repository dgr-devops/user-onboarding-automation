#!/usr/bin/env bats
# Tests de la carga y validación de la política (lib/policy.sh), vía onboard-users.sh.

load test_helper

setup() { setup_env; }
teardown() { cleanup_env; }

# expect_policy_error <mensaje> — la política actual debe rechazarse con 64.
expect_policy_error() {
  run "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY"
  [ "$status" -eq 64 ]
  [[ "$output" == *"$1"* ]]
}

@test "la política de ejemplo es válida" {
  run "$ONBOARD" --csv "$EXAMPLE_CSV" --config "${PROJECT_ROOT}/config/policy.conf.example"
  [ "$status" -eq 0 ]
}

@test "una política vacía usa los valores por defecto" {
  : >"$POLICY"
  run "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"caduca="* ]]
}

@test "rechaza una clave desconocida" {
  echo "ALLOWED_PORTS=22" >>"$POLICY"
  expect_policy_error "clave desconocida 'ALLOWED_PORTS'"
}

@test "rechaza una línea sin formato CLAVE=valor" {
  echo "esto no es valido" >>"$POLICY"
  expect_policy_error "no tiene formato CLAVE=valor"
}

@test "no ejecuta código incrustado en los valores" {
  echo 'DEFAULT_SHELL=$(touch /tmp/uoa-pwned)' >>"$POLICY"
  expect_policy_error "DEFAULT_SHELL"
  [ ! -e /tmp/uoa-pwned ]
}

@test "rechaza valores numéricos inválidos" {
  set_policy PASS_MAX_DAYS noventa
  expect_policy_error "PASS_MAX_DAYS debe ser un entero"
}

@test "rechaza una contraseña temporal demasiado corta" {
  set_policy PASSWORD_LENGTH 8
  expect_policy_error "PASSWORD_LENGTH"
}

@test "rechaza PASS_MIN_DAYS mayor que PASS_MAX_DAYS" {
  set_policy PASS_MIN_DAYS 100
  expect_policy_error "PASS_MIN_DAYS"
}

@test "rechaza un MIN_UID que expondría cuentas de sistema" {
  set_policy MIN_UID 0
  expect_policy_error "MIN_UID"
}

@test "rechaza HOME_BASE=/ " {
  set_policy HOME_BASE /
  expect_policy_error "HOME_BASE"
}

@test "rechaza una expresión regular de usuario inválida" {
  set_policy USERNAME_REGEX '^[a-z'
  expect_policy_error "USERNAME_REGEX"
}

@test "rechaza una shell por defecto fuera de la lista permitida" {
  set_policy DEFAULT_SHELL /bin/zsh
  expect_policy_error "DEFAULT_SHELL"
}
