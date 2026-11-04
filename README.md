# MicroDeploy

Herramienta de despliegue automatizado para proyectos de NebulaCSF, escrita en **Go** (binario autocontenido). Realiza merge a la rama principal (`main`/`master`), push a GitHub y actualización de un servidor remoto vía SSH.

---

## Requisitos previos

- **Git** instalado y repositorio inicializado
- **Go** (solo para compilar el binario; no es necesario en el equipo de destino)
- **Acceso SSH sin contraseña** (claves SSH configuradas) a cada servidor remoto
- Cada directorio remoto debe ser un repositorio git con remote `origin`
- Permisos de escritura en el directorio remoto
- `sudo` sin contraseña en el servidor remoto (necesario para `./service.sh restart` cuando se usa `--restart-systemd`)

---

## Instalación

Compilar el binario:

```bash
make build            # genera el binario 'microdeploy' en el directorio actual
# o directamente:
go build -o microdeploy main.go
```

Instalar en el sistema (opcional):

```bash
make install          # instala en /usr/local/bin (PREFIX para cambiar destino)
# o manualmente:
sudo mv microdeploy /usr/local/bin/
```

El binario es autocontenido: no requiere Bash, se puede copiar a cualquier máquina compatible. La configuración se guarda en `$HOME/.microdeploy/remotes.conf`.

---

## Archivos

| Archivo | Descripción |
|---------|-------------|
| `main.go` | Código fuente Go del despliegue (compila al binario `microdeploy`) |
| `Makefile` | Targets de build/install/test/clean |
| `remotes.conf` | Configuración de servidores remotos (formato `nombre\|user@host\|dir_local\|dir_remoto\|rama\|main_branch`) |

---

## Configuración de remotos (`remotes.conf`)

Formato: `nombre|user@host|directorio_local|directorio_remoto|rama|main_branch`

```
produccion|ubuntu@192.168.1.100|/home/jose/mi-proyecto|/home/ubuntu/mi-proyecto|main|main
staging|deploy@staging.empresa.com|/home/jose/mi-proyecto|/opt/mi-proyecto|develop|main
```

Campos:

| Campo | Descripción |
|-------|-------------|
| `nombre` | Identificador único del remoto |
| `user@host` | Conexión SSH al servidor |
| `directorio_local` | Repositorio git **local**: aquí se hace `git checkout <main_branch>`, el merge de tu rama actual y el push a GitHub |
| `directorio_remoto` | Repositorio git en el **servidor**: aquí se hace `git pull origin <rama>` |
| `rama` | Rama que se actualiza en el servidor con `git pull` (default `main`) |
| `main_branch` | Rama principal del repo local, `main` o `master` (default `main`) |

- Se ignoran líneas vacías y comentarios (`#`)
- `rama` y `main_branch` pueden omitirse y toman el valor `main`
- Las entradas en el formato antiguo de 4 campos (`nombre|user@host|dir_remoto|rama`) se migran automáticamente con un aviso: directorio local = directorio donde está el script y `main_branch = main`

También puedes gestionar remotos de forma interactiva:

```bash
./microdeploy --add
./microdeploy --remove staging
```

---

## Uso

### Ver la configuración actual

```bash
./microdeploy      # sin argumentos: imprime los remotos configurados
./microdeploy --list
```

### Desplegar a un remoto específico

```bash
./microdeploy produccion
```

> ⚠️ **Importante:** el despliegue **siempre** requiere indicar el remoto objetivo. No existe opción para actualizar "todos" los remotos a la vez.

Por defecto el despliegue **no** ejecuta `./service.sh restart` en el remoto (para proyectos que no lo usan). Si quieres reiniciar el servicio, añade el flag `--restart-systemd`:

```bash
./microdeploy produccion --restart-systemd
```

### Crear y pushear un tag (opcional)

```bash
./microdeploy --tag v1.2.3 produccion
./microdeploy --tag v1.2.3 produccion --restart-systemd   # tag + reinicio
```

### Gestión de configuración

```bash
./microdeploy --list              # Lista remotos configurados
./microdeploy --add               # Agrega un remoto interactivamente
./microdeploy --remove <nombre>   # Elimina un remoto
./microdeploy --status            # Estado de todos los remotos (comparación de commits)
./microdeploy --status <nombre>   # Estado de un remoto específico
./microdeploy --help              # Muestra ayuda
```

### Ver estado de sincronización (`--status`)

Compara la **rama actual del repo local** con la **rama configurada del servidor** y muestra cuántos commits de diferencia hay:

```bash
./microdeploy --status              # todos los remotos
./microdeploy --status produccion   # solo un remoto
```

```text
[STATUS] produccion (ubuntu@192.168.1.100:/home/ubuntu/mi-proyecto)
  local  (dev       ): a1b2c3d
  remoto (main      ): e4f5g6h
[WARN] El remoto 'produccion' está 2 commits ATRASADO (despliegue pendiente)
```

Resultados posibles:

| Resultado | Significado |
|-----------|-------------|
| `Actualizado (al día)` | Local y servidor están en el mismo commit |
| `Atrasado N commits` | El local tiene commits que el servidor no (despliegue pendiente) |
| `Adelantado N commits` | El servidor tiene commits que el local no tiene |
| `Divergieron` | Ambas partes tienen commits propios |

> ℹ️ Para comparar se consulta el servidor vía SSH con `git fetch` (escribe solo en `FETCH_HEAD`: no modifica refs ni el código local). Requiere acceso SSH sin contraseña, igual que el despliegue.

---

## Proceso de despliegue

El script ejecuta los siguientes pasos **en orden**:

### Pasos locales (en `directorio_local`)

1. Guarda la rama actual como `CURRENT_BRANCH`
2. `git checkout <main_branch>` (rama principal configurada: `main` o `master`)
3. `git merge --no-edit CURRENT_BRANCH`
4. `git tag <tag>` _(solo si se pasa `--tag`)_
5. `git checkout CURRENT_BRANCH`
6. `git push github <main_branch> dev`
7. `git push github <tag>` _(solo si se pasó `--tag`)_

### Pasos remotos

Vía SSH:

1. `cd <directorio_remoto>`
2. `git pull origin <rama>`
3. `./service.sh restart` _(solo si se pasó `--restart-systemd`)_

---

## Estructura de `service.sh` (en cada remoto)

El script remoto debe existir en el directorio del proyecto y exponer los comandos (solo se ejecuta cuando se usa `--restart-systemd`):

```bash
./service.sh restart
```

Requiere permisos de `sudo` sin contraseña en el servidor remoto.

---

## Ejemplos comunes

```bash
# Ver remotos configurados
./microdeploy
./microdeploy --list

# Desplegar en producción (sin reiniciar servicio)
./microdeploy produccion

# Desplegar en producción y reiniciar el servicio
./microdeploy produccion --restart-systemd

# Desplegar en producción con tag y reiniciar el servicio
./microdeploy --tag v2.0.0 produccion --restart-systemd

# Ver si el servidor está al día con el repo local
./microdeploy --status
./microdeploy --status produccion

# Agregar un nuevo servidor
./microdeploy --add
```

---

## Flujo de ramas

- Los cambios se desarrollan en cualquier rama (`dev`, `feature/*`, etc.)
- Al ejecutar `microdeploy <remoto>` desde esa rama: se hace merge a la rama principal configurada (`main`/`master`) automáticamente en el `directorio_local`
- Se pushea la rama principal y `dev` a `github`
- Si algo falla antes del push, el repo queda en la rama original (validación previa del tag)

> ⚠️ **Nota:** `git push github <main_branch> dev` asume que la rama `dev` existe localmente. Si no aplica a tu proyecto, ajusta el script.

---

## Manejo de errores

- El script usa `set -euo pipefail` (falla ante cualquier error)
- Se valida que el tag no exista **antes** de modificar ramas
- Se valida que el remoto objetivo exista **antes** de tocar el repositorio local
- Código de salida distinto de `0` si algo falla

---

## Solución de problemas

| Problema | Solución |
|----------|----------|
| `No se puede conectar via SSH` | Verificar clave SSH: `ssh user@host true` |
| `git pull` falla en remoto | Revisar que el directorio remoto tenga remote `origin` y permisos |
| `./service.sh restart` falla | Verificar que el usuario SSH tenga `sudo` sin contraseña y que se usó `--restart-systemd` |
| `El tag ya existe` | Usar otro nombre de tag o borrar el existente |
| Merge con conflictos | Resolver manualmente; el script se detiene |
| `'...' no es un repositorio git` | Revisar el campo `directorio_local` en `remotes.conf` |
| `No se encontró remoto` | Verificar el nombre con `./microdeploy --list` |

---

## Desinstalación

```bash
rm microdeploy remotes.conf
```