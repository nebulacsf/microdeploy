#!/usr/bin/env bash
# ============================================================
# deploy.sh - Desplegar cambios: merge a main, push y actualizar remotos
# ============================================================
# Proceso:
#   1. git checkout main
#   2. git merge <rama actual>            (CURRENT_BRANCH)
#   3. git tag <tag> (opcional, sobre main)
#   4. git checkout <rama actual>
#   5. git push github main dev
#   6. git push github <tag> (si se indicó --tag)
#   7. En cada remoto (SSH): git pull + ./service.sh restart
#
# Uso:
#   ./deploy.sh                # Despliega y actualiza todos los remotos configurados
#   ./deploy.sh <nombre>       # Despliega y actualiza solo el remoto especificado
#   ./deploy.sh --tag <tag>    # Despliega y además crea y pushea un tag a github
#   ./deploy.sh --tag <tag> <nombre> # Ídem limitado a un remoto
#   ./deploy.sh --list         # Lista los remotos configurados
#   ./deploy.sh --add          # Agrega un remoto interactivamente
#   ./deploy.sh --remove <nombre> # Elimina un remoto
#   ./deploy.sh --help         # Muestra esta ayuda
#
# Configuración en: remotes.conf (formato: nombre|user@host|directorio|rama)
# Nota: el paso 5 ejecuta ./service.sh restart en el remoto; ese comando
#       requiere permisos de root en el servidor (sudo sin contraseña).
# ============================================================

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/remotes.conf"

# Funciones de utilidad
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERR]${NC} $*"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $*"; }

# Cargar configuración
load_remotes() {
    REMOTES=()
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return
    fi
    while IFS='|' read -r name host dir branch; do
        # Ignorar líneas vacías y comentarios
        [[ -z "${name// }" ]] && continue
        [[ "${name}" =~ ^#.* ]] && continue
        REMOTES+=("${name}|${host}|${dir}|${branch}")
    done < "${CONFIG_FILE}"
}

# Guardar configuración
save_remotes() {
    printf '%s\n' "${REMOTES[@]}" > "${CONFIG_FILE}"
}

# Listar remotos
cmd_list() {
    load_remotes
    if [[ ${#REMOTES[@]} -eq 0 ]]; then
        log_warn "No hay remotos configurados. Usa '$0 --add' para agregar uno."
        return
    fi
    echo -e "${CYAN}Remotos configurados:${NC}"
    printf "%-20s %-30s %-40s %s\n" "NOMBRE" "HOST" "DIRECTORIO" "RAMA"
    printf "%-20s %-30s %-40s %s\n" "──────" "────" "────────" "────"
    for entry in "${REMOTES[@]}"; do
        IFS='|' read -r name host dir branch <<< "${entry}"
        printf "%-20s %-30s %-40s %s\n" "${name}" "${host}" "${dir}" "${branch}"
    done
}

# Agregar remoto
cmd_add() {
    load_remotes
    echo -e "${CYAN}Agregar nuevo remoto${NC}"
    read -rp "Nombre (ej. produccion): " name
    read -rp "Usuario@Host (ej. ubuntu@192.168.1.100): " host
    read -rp "Directorio remoto (ej. /home/ubuntu/baileys-bridge): " dir
    read -rp "Rama (default: main): " branch
    branch="${branch:-main}"

    # Validar que no exista
    for entry in "${REMOTES[@]}"; do
        IFS='|' read -r n _ _ _ <<< "${entry}"
        if [[ "${n}" == "${name}" ]]; then
            log_err "Ya existe un remoto con nombre '${name}'"
            return 1
        fi
    done

    REMOTES+=("${name}|${host}|${dir}|${branch}")
    save_remotes
    log_ok "Remoto '${name}' agregado"
}

# Eliminar remoto
cmd_remove() {
    local target="${1:-}"
    if [[ -z "${target}" ]]; then
        log_err "Debes especificar el nombre del remoto a eliminar"
        return 1
    fi

    load_remotes
    local new_remotes=()
    local found=false
    for entry in "${REMOTES[@]}"; do
        IFS='|' read -r name _ _ _ <<< "${entry}"
        if [[ "${name}" == "${target}" ]]; then
            found=true
        else
            new_remotes+=("${entry}")
        fi
    done

    if [[ "${found}" == false ]]; then
        log_err "No se encontró remoto '${target}'"
        return 1
    fi

    REMOTES=("${new_remotes[@]}")
    save_remotes
    log_ok "Remoto '${target}' eliminado"
}

# Pasos locales: merge de la rama actual a main y push a github
#   git checkout main && git merge CURRENT_BRANCH && git tag <tag> && git checkout CURRENT_BRANCH && git push github main dev && git push github <tag>
# El tag (opcional) se crea sobre main, apuntando al commit ya mergeado.
deploy_local() {
    local tag="${1:-}"

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_err "No estás dentro de un repositorio git"
        return 1
    fi

    local current_branch
    current_branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ -z "${current_branch}" || "${current_branch}" == "HEAD" ]]; then
        log_err "No se pudo determinar la rama actual"
        return 1
    fi

    log_info "Rama actual (CURRENT_BRANCH): ${current_branch}"

    # Validar el tag antes de tocar las ramas para no dejar el repo a medias
    if [[ -n "${tag}" ]] && git rev-parse --verify "refs/tags/${tag}" >/dev/null 2>&1; then
        log_err "El tag '${tag}' ya existe"
        return 1
    fi

    log_step "git checkout main"
    git checkout main

    log_step "git merge --no-edit ${current_branch}"
    git merge --no-edit "${current_branch}"

    if [[ -n "${tag}" ]]; then
        log_step "git tag ${tag}"
        git tag "${tag}"
    fi

    log_step "git checkout ${current_branch}"
    git checkout "${current_branch}"

    log_step "git push github main dev"
    git push github main dev

    if [[ -n "${tag}" ]]; then
        log_step "git push github ${tag}"
        git push github "${tag}"
    fi

    if [[ -n "${tag}" ]]; then
        log_ok "Pasos locales completados: main actualizada, pusheada a github (tag: ${tag})"
    else
        log_ok "Pasos locales completados: main actualizada y pusheada a github"
    fi
}

# Actualizar un remoto (git pull + reinicio del servicio systemd)
update_remote() {
    local name="${1}"
    local host="${2}"
    local dir="${3}"
    local branch="${4}"

    log_step "Actualizando ${name} (${host}:${dir})..."

    # Verificar conectividad SSH
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "${host}" "true" 2>/dev/null; then
        log_err "No se puede conectar a ${host} via SSH"
        return 1
    fi

    # En el remoto: git pull + ./service.sh restart
    local cmd="
        set -euo pipefail
        cd '${dir}' || { echo 'Directorio no existe'; exit 1; }
        echo 'Directorio actual: '\$(pwd)
        git pull origin '${branch}' 2>&1
        echo 'Git pull completado'
        ./service.sh restart 2>&1
        echo 'Servicio reiniciado'
    "

    if ssh "${host}" "${cmd}"; then
        log_ok "${name} actualizado correctamente"
        return 0
    else
        log_err "Error actualizando ${name}"
        return 1
    fi
}

# Parsear argumentos de despliegue: --tag <tag> y opcional <nombre-remoto>
# Establece las variables globales TAG y TARGET.
parse_deploy_args() {
    TAG=""
    TARGET=""
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --tag|-t)
                if [[ $# -lt 2 || -z "${2}" ]]; then
                    log_err "El parámetro --tag requiere un nombre de tag (ej. v1.2.3)"
                    return 1
                fi
                TAG="${2}"
                shift 2
                ;;
            -*)
                log_err "Argumento desconocido: ${1}"
                return 1
                ;;
            *)
                if [[ -n "${TARGET}" ]]; then
                    log_err "Argumento inesperado: ${1}"
                    return 1
                fi
                TARGET="${1}"
                shift
                ;;
        esac
    done
}

# Desplegar: pasos locales + actualizar todos o uno específico
cmd_deploy() {
    if ! command -v git >/dev/null 2>&1; then
        log_err "git no está disponible en este sistema"
        return 1
    fi

    # Pasos locales (merge a main + push + tag opcional), siempre antes de tocar remotos
    deploy_local "${TAG}"

    load_remotes
    if [[ ${#REMOTES[@]} -eq 0 ]]; then
        log_warn "No hay remotos configurados. Usa '$0 --add' para agregar uno."
        return 1
    fi

    local failed=0
    local success=0

    for entry in "${REMOTES[@]}"; do
        IFS='|' read -r name host dir branch <<< "${entry}"

        if [[ -n "${TARGET}" && "${name}" != "${TARGET}" ]]; then
            continue
        fi

        if update_remote "${name}" "${host}" "${dir}" "${branch}"; then
            ((success++))
        else
            ((failed++))
        fi
        echo
    done

    echo -e "${CYAN}Resumen:${NC} ${success} exitosos, ${failed} fallidos"
    if [[ ${failed} -gt 0 ]]; then
        return 1
    fi
}

# Mostrar ayuda
show_help() {
    cat <<EOF
${CYAN}deploy.sh${NC} - Desplegar cambios: merge a main, push y actualizar remotos

${BLUE}Proceso:${NC}
  1. git checkout main
  2. git merge <rama actual>
  3. git tag <tag> (opcional, sobre main)
  4. git checkout <rama actual>
  5. git push github main dev
  6. git push github <tag> (si se indicó --tag)
  7. En cada remoto (SSH): git pull + ./service.sh restart

${BLUE}Uso:${NC}
  $0                    Despliega y actualiza todos los remotos
  $0 <nombre>           Despliega y actualiza solo el remoto especificado
  $0 --tag <tag>        Despliega y además crea y pushea un tag a github
  $0 --tag <tag> <nombre>  Ídem limitado al remoto especificado
  $0 --list             Lista los remotos configurados
  $0 --add              Agrega un remoto interactivamente
  $0 --remove <nombre>  Elimina un remoto
  $0 --help             Muestra esta ayuda

${BLUE}Archivo de configuración:${NC} ${CONFIG_FILE}
Formato: nombre|user@host|directorio|rama

${BLUE}Ejemplo remotes.conf:${NC}
  produccion|ubuntu@192.168.1.100|/home/ubuntu/baileys-bridge|main
  staging|deploy@staging.empresa.com|/opt/baileys-bridge|develop

${BLUE}Requisitos:${NC}
  - Acceso SSH sin contraseña (claves SSH) a los servidores remotos
  - El directorio remoto debe ser un repositorio git con remote 'origin'
  - El usuario SSH debe tener permisos de escritura en el directorio
  - ./service.sh restart requiere permisos de root en el servidor (sudo)

${BLUE}Ejemplos:${NC}
  $0                               # Despliega y actualiza todos
  $0 produccion                    # Despliega y actualiza solo 'produccion'
  $0 --tag v1.2.3                  # Despliega y crea/pushea el tag v1.2.3
  $0 --tag v1.2.3 produccion       # Tag + solo el remoto 'produccion'
  $0 --add                         # Agrega nuevo remoto
  $0 --remove staging              # Elimina 'staging'
EOF
}

# Main
case "${1:-}" in
    --list|-l)
        cmd_list
        ;;
    --add|-a)
        cmd_add
        ;;
    --remove|-r)
        cmd_remove "${2:-}"
        ;;
    --help|-h)
        show_help
        ;;
    *)
        if ! parse_deploy_args "$@"; then
            exit 1
        fi
        cmd_deploy
        ;;
esac
