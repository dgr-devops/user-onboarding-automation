# Políticas de cuentas

Esta página explica qué impone cada clave de `config/policy.conf` y por qué. El fichero se lee como
`CLAVE=valor` sin ejecutarlo: no hay variables, ni sustituciones, ni `source`. Una clave desconocida o un
valor fuera de rango detiene el script con código 64 antes de tocar nada.

## Validación de entradas

| Clave | Por defecto | Efecto |
| --- | --- | --- |
| `USERNAME_REGEX` | `^[a-z][a-z0-9._-]{2,31}$` | Todo `username` del CSV debe cumplirla. Empieza por letra minúscula, 3–32 caracteres. |
| `ALLOWED_GROUPS` | `developers sysadmin support` | Único conjunto de grupos que el CSV puede asignar. Los que no existen se crean con `groupadd`. Un grupo como `root` o `sudo` se rechaza porque no está en la lista. |
| `ALLOWED_SHELLS` | `/bin/bash /bin/sh /usr/sbin/nologin` | Shells aceptadas. Además debe existir y ser ejecutable en el sistema. |
| `DEFAULT_SHELL` | `/bin/bash` | Shell si el CSV la deja vacía. Debe estar en `ALLOWED_SHELLS`. |

Otras comprobaciones que no se configuran: cabecera exacta del CSV, 5 campos por fila, usuarios duplicados,
`full_name` sin `:` ni caracteres de control (iría al campo GECOS de `/etc/passwd`), `department` alfanumérico.

## Protección de cuentas ajenas

| Clave | Por defecto | Efecto |
| --- | --- | --- |
| `MIN_UID` | `1000` | Una cuenta con UID menor es **de sistema**: el alta la rechaza como colisión, la baja se niega a tocarla y la auditoría la marca. Mínimo permitido: 500. |
| `HOME_BASE` | `/home` | Los homes se crean en `HOME_BASE/usuario`. La baja solo archiva o borra homes estrictamente dentro de esta ruta (nunca `/`, `/root` o `/srv/...`). |
| `HOME_MODE` | `0750` | Permisos del home: el grupo primario puede entrar, el resto no. |

## Contraseña temporal y envejecimiento

| Clave | Por defecto | Se aplica con | Significado |
| --- | --- | --- | --- |
| `PASSWORD_LENGTH` | `20` | generador propio | Longitud (12–64). Alfabeto sin caracteres ambiguos (`0 O 1 l I`), siempre con mayúscula, minúscula y dígito. |
| `PASS_MAX_DAYS` | `90` | `chage -M` | Días máximos entre cambios (`0` = sin límite). |
| `PASS_MIN_DAYS` | `1` | `chage -m` | Días mínimos entre cambios. No puede superar el máximo. |
| `PASS_WARN_DAYS` | `14` | `chage -W` | Días de aviso antes de caducar. |
| `INACTIVE_DAYS` | `30` | `chage -I` | Días de gracia tras caducar la contraseña antes de bloquear la cuenta (`0` = sin bloqueo). |
| `ACCOUNT_EXPIRY_DAYS` | `365` | `chage -E` | La cuenta caduca a los N días de crearse (`0` = no caduca). Obliga a renovar o dar de baja. |

Además, cada cuenta nueva sale con `chage -d 0`: la contraseña temporal **solo sirve para entrar y
cambiarla**; el sistema la exige en el primer inicio de sesión.

## Qué pasa con la contraseña temporal

1. Se genera con `/dev/urandom` y se asigna con `chpasswd` leyendo de la entrada estándar (no aparece en la
   lista de procesos).
2. Se escribe en `REPORT_DIR/onboarding-<fecha>-<pid>.csv`: directorio `0700`, fichero `0600`, propietario root.
3. **Nunca** se imprime en pantalla ni en los logs. Los tests lo comprueban buscando cada contraseña en la salida.
4. El informe se crea solo si se crea alguna cuenta; si la escritura falla, la cuenta recién creada se deshace
   (`userdel -r`) para no dejar usuarios sin contraseña conocida.
5. Entregar la contraseña al usuario y borrar el informe cuando ya no haga falta es responsabilidad de quien opera.

## Baja de usuarios

| Clave | Por defecto | Efecto |
| --- | --- | --- |
| `ARCHIVE_DIR` | `/var/backups/offboarding` | Copias `usuario-AAAAMMDD-HHMMSS.tar.gz`, directorio `0700`, ficheros `0600`. |

Orden: bloquear (`usermod -L`) → caducar (`chage -E` con la fecha de ayer) → archivar el home y verificar el
archivo con `tar -tzf` → **solo si se pidió `--delete-home` y el archivo es válido**, `userdel -r`.
Sin `--delete-home` la cuenta queda bloqueada y caducada, y el home intacto.

## Auditoría

| Nivel | Hallazgo |
| --- | --- |
| CRITICAL | Usuario del CSV que no existe. Cuenta con UID de usuario fuera del CSV y con contraseña activa. Cuenta de sistema listada en el CSV. |
| WARNING | Cuenta bloqueada o caducada. Contraseña con más días que `PASS_MAX_DAYS`. `PASS_MAX_DAYS` de la cuenta distinto al de la política. Shell, grupos o home distintos de los del CSV. Cuenta fuera del CSV pero bloqueada (baja pendiente de limpiar). |
| INFO | Cambio de contraseña pendiente (estado normal de una cuenta recién creada; no cuenta como hallazgo). |

El código de salida es el del hallazgo más grave: `0`, `1` (WARNING) o `2` (CRITICAL).
