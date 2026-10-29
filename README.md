# MicroDeploy

Script de despliegue automatizado para proyectos de NebulaCSF. Realiza merge a la rama principal (`main`/`master`), push a GitHub y actualización de un servidor remoto vía SSH.

---

## Requisitos previos

- **Bash** 4.0+ (Linux/macOS)
- **Git** instalado y repositorio inicializado
- **Acceso SSH sin contraseña** (claves SSH configuradas) a cada servidor remoto
- Cada directorio remoto debe ser un repositorio git con remote `origin`
- Permisos de escritura en el directorio remoto
- `sudo` sin contraseña en el servidor remoto (necesario para `./service.sh restart`)

---

## Instalación

```bash
# Copiar los archivos al proyecto
cp microdeploy.sh /ruta/del/proyecto/
chmod +x microdeploy.sh

# Crear el archivo de configuración de remotos
touch remotes.conf
```

---

## Archivos

| Archivo | Descripción |
|---------|-------------|
| `microdeploy.sh` | Script principal de despliegue |
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
./microdeploy.sh --add
./microdeploy.sh --remove staging
```

---

## Uso

### Ver la configuración actual

```bash
./microdeploy.sh      # sin argumentos: imprime los remotos configurados
./microdeploy.sh --list
```

### Desplegar a un remoto específico

```bash
./microdeploy.sh produccion
```

> ⚠️ **Importante:** el despliegue **siempre** requiere indicar el remoto objetivo. No existe opción para actualizar "todos" los remotos a la vez.

### Crear y pushear un tag (opcional)

```bash
./microdeploy.sh --tag v1.2.3 produccion
```

### Gestión de configuración

```bash
./microdeploy.sh --list              # Lista remotos configurados
./microdeploy.sh --add               # Agrega un remoto interactivamente
./microdeploy.sh --remove <nombre>   # Elimina un remoto
./microdeploy.sh --help              # Muestra ayuda
```

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
3. `./service.sh restart`

---

## Estructura de `service.sh` (en cada remoto)

El script remoto debe existir en el directorio del proyecto y exponer los comandos:

```bash
./service.sh restart
```

Requiere permisos de `sudo` sin contraseña en el servidor remoto.

---

## Ejemplos comunes

```bash
# Ver remotos configurados
./microdeploy.sh
./microdeploy.sh --list

# Desplegar en producción
./microdeploy.sh produccion

# Desplegar en producción con tag
./microdeploy.sh --tag v2.0.0 produccion

# Agregar un nuevo servidor
./microdeploy.sh --add
```

---

## Flujo de ramas

- Los cambios se desarrollan en cualquier rama (`dev`, `feature/*`, etc.)
- Al ejecutar `microdeploy.sh <remoto>` desde esa rama: se hace merge a la rama principal configurada (`main`/`master`) automáticamente en el `directorio_local`
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
| `./service.sh restart` falla | Verificar que el usuario SSH tenga `sudo` sin contraseña |
| `El tag ya existe` | Usar otro nombre de tag o borrar el existente |
| Merge con conflictos | Resolver manualmente; el script se detiene |
| `'...' no es un repositorio git` | Revisar el campo `directorio_local` en `remotes.conf` |
| `No se encontró remoto` | Verificar el nombre con `./microdeploy.sh --list` |

---

## Desinstalación

```bash
rm microdeploy.sh remotes.conf
```