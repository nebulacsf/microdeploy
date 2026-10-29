# MicroDeploy

Script de despliegue automatizado para proyectos de NebulaCSF. Realiza merge a `main`, push a GitHub y actualización en servidores remotos vía SSH.

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
| `remotes.conf` | Configuración de servidores remotos (formato `nombre\|user@host\|directorio\|rama`) |

---

## Configuración de remotos (`remotes.conf`)

Formato: `nombre|user@host|directorio|rama`

```
produccion|ubuntu@192.168.1.100|/home/ubuntu/mi-proyecto|main
staging|deploy@staging.empresa.com|/opt/mi-proyecto|develop
```

- Se ignoran líneas vacías y comentarios (`#`)
- Cada entrada debe tener exactamente 4 campos separados por `|`

También puedes gestionar remotos de forma interactiva:

```bash
./microdeploy.sh --add
./microdeploy.sh --remove staging
```

---

## Uso

### Desplegar a todos los remotos

```bash
./microdeploy.sh
```

### Desplegar a un remoto específico

```bash
./microdeploy.sh produccion
```

### Crear y pushear un tag (opcional)

```bash
./microdeploy.sh --tag v1.2.3
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

### Pasos locales (siempre)

1. Guarda la rama actual como `CURRENT_BRANCH`
2. `git checkout main`
3. `git merge --no-edit CURRENT_BRANCH`
4. `git tag <tag>` _(solo si se pasa `--tag`)_
5. `git checkout CURRENT_BRANCH`
6. `git push github main dev`
7. `git push github <tag>` _(solo si se pasó `--tag`)_

### Pasos remotos (por cada servidor)

Vía SSH:

1. `cd <directorio>`
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
# Despliegue completo (todos los remotos)
./microdeploy.sh

# Solo a producción, con tag
./microdeploy.sh --tag v2.0.0 produccion

# Ver configuración actual
./microdeploy.sh --list

# Agregar un nuevo servidor
./microdeploy.sh --add
```

---

## Flujo de ramas

- Los cambios se desarrollan en cualquier rama (`dev`, `feature/*`, etc.)
- Al ejecutar `microdeploy.sh` desde esa rama, se hace merge a `main` automáticamente
- Se pushea `main` y `dev` a `github`
- Si algo falla antes del push, el repo queda en la rama original (validación previa del tag)

> ⚠️ **Nota:** `git push github main dev` asume que la rama `dev` existe localmente. Si no aplica a tu proyecto, ajusta el script.

---

## Manejo de errores

- El script usa `set -euo pipefail` (falla ante cualquier error)
- Se valida que el tag no exista **antes** de modificar ramas
- Si un remoto falla, el script continúa con los demás y muestra un resumen al final
- Código de salida distinto de `0` si algún remoto falla

---

## Solución de problemas

| Problema | Solución |
|----------|----------|
| `No se puede conectar via SSH` | Verificar clave SSH: `ssh user@host true` |
| `git pull` falla en remoto | Revisar que el directorio tenga remote `origin` y permisos |
| `./service.sh restart` falla | Verificar que el usuario SSH tenga `sudo` sin contraseña |
| `El tag ya existe` | Usar otro nombre de tag o borrar el existente |
| Merge con conflictos | Resolver manualmente; el script se detiene |

---

## Desinstalación

```bash
rm microdeploy.sh remotes.conf
```
