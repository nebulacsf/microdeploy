#!/usr/bin/env bash
# ============================================================
# deploy.sh - Desplegar cambios: merge a la rama principal, push y actualizar remoto
# ============================================================
# Proceso:
#   1. git checkout <main_branch>            (rama principal: main o master)
#   2. git merge <rama actual>               (CURRENT_BRANCH)
#   3. git tag <tag> (opcional, sobre la rama principal)
#   4. git checkout <rama actual>
#   5. git push ${git_remote} <main_branch> dev
#   6. git push ${git_remote} <tag> (si se indicó --tag)
#   7. En el remoto (SSH): git pull + ./service.sh restart
#
# Uso:
#   ./deploy.sh                # Lista los remotos configurados
#   ./deploy.sh <nombre>       # Despliega y actualiza solo el remoto especificado
#   ./deploy.sh --tag <tag> <nombre> # Ídem, además crea y pushea un tag a github
#   ./deploy.sh --list         # Lista los remotos configurados
#   ./deploy.sh --add          # Agrega un remoto interactivamente
#   ./deploy.sh --remove <nombre> # Elimina un remoto
#   ./deploy.sh --help         # Muestra esta ayuda
#
# Configuración en: remotes.conf (formato: nombre|user@host|directorio_local|directorio_remoto|rama|main_branch)
# Nota: el paso 7 ejecuta ./service.sh restart en el remoto; ese comando
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
# Formato: nombre|user@host|directorio_local|directorio_remoto|rama|main_branch|remoto_git
load_remotes() {
    REMOTES=()
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return
    fi
    while IFS= read -r line; do
        # Ignorar líneas vacías y comentarios
        [[ -z "${line// }" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*#.* ]] && continue

        IFS='|' read -ra f <<< "${line}"
        local n="${#f[@]}"

        if [[ ${n} -eq 4 ]]; then
            # Formato viejo (4 campos): nombre|user@host|dir_remoto|rama
            log_warn "Remoto '${f[0]}' en formato antiguo: se usa '${SCRIPT_DIR}' como directorio local, 'main' como rama principal y 'github' como remoto git"
            REMOTES+=("${f[0]}|${f[1]}|${SCRIPT_DIR}|${f[2]}|${f[3]}|main|github")
            continue
        fi

        if [[ ${n} -eq 5 || ${n} -eq 6 || ${n} -eq 7 ]]; then
            # nombre|host|dir_local|dir_remoto|rama|main_branch|git_remote
            REMOTES+=("${f[0]}|${f[1]}|${f[2]}|${f[3]}|${f[4]:-main}|${f[5]:-main}|${f[6]:-github}")
            continue
        fi

        log_warn "Línea ignorada (${n} campos): ${line}"
    done < "${CONFIG_FILE}"
}

# Guardar configuración
save_remotes() {
    printf '%s\n' "${REMOTES[@]}" > "${CONFIG_FILE}"
}

# Truncar string si excede un ancho máximo
truncate_str() {
    local str="$1"
    local max="$2"
    if [[ ${#str} -le ${max} ]]; then
        printf '%s' "${str}"
    else
        printf '%s...' "${str:0:$((max-3))}"
    fi
}

# Listar remotos
cmd_list() {
    load_remotes
    if [[ ${#REMOTES[@]} -eq 0 ]]; then
        log_warn "No hay remotos configurados. Usa '$0 --add' para agregar uno."
        return
    fi
    echo -e "${CYAN}Remotos configurados:${NC}"
    printf "%-16s %-24s\n" "NOMBRE" "USUARIO@HOST"
    printf "%-16s %-24s\n" "──────" "────"
    for entry in "${REMOTES[@]}"; do
        IFS='|' read -r name host local_dir remote_dir branch main_branch git_remote <<< "${entry}"
        printf "%-16s %-24s\n" "$(truncate_str "${name}" 16)" "$(truncate_str "${host}" 24)"
    done
}

# Inspeccionar remoto (detalles completos)
cmd_inspect() {
    local target="${1:-}"
    if [[ -z "${target}" ]]; then
        log_err "Debes especificar el nombre del remoto (ej. $0 --inspect produccion)"
        return 1
    fi

    load_remotes
    local found=false
    for entry in "${REMOTES[@]}"; do
        IFS='|' read -r name host local_dir remote_dir branch main_branch git_remote <<< "${entry}"
        if [[ "${name}" == "${target}" ]]; then
            found=true
            echo -e "${CYAN}Detalles del remoto:${NC} ${name}"
            echo "  Nombre remoto:        ${name}"
            echo "  Usuario@Host:         ${host}"
            echo "  Directorio local:     ${local_dir}"
            echo "  Directorio remoto:    ${remote_dir}"
            echo "  Rama:                  ${branch}"
            echo "  Rama principal:        ${main_branch}"
            echo "  Remoto git:           ${git_remote:-github}"
        fi
    done
    if [[ "${found}" == false ]]; then
        log_err "No se encontró remoto '${target}'"
        return 1
    fi
}

# Agregar remoto
cmd_add() {
    load_remotes
    echo -e "${CYAN}Agregar nuevo remoto${NC}"
    read -rp "Nombre (ej. produccion): " name
    read -rp "Usuario@Host (ej. ubuntu@192.168.1.100): " host
    read -rp "Directorio local del proyecto (ej. /home/jose/mi-proyecto): " local_dir
    read -rp "Directorio remoto (ej. /home/ubuntu/mi-proyecto): " remote_dir
    read -rp "Rama a desplegar en el remoto (default: main): " branch
    branch="${branch:-main}"
    read -rp "Rama principal local, main/master (default: main): " main_branch
    main_branch="${main_branch:-main}"
    read -rp "Remoto git para push (default: github): " git_remote
    git_remote="${git_remote:-github}"

    # Validar que no exista
    for entry in "${REMOTES[@]}"; do
        IFS='|' read -r n _ _ _ _ _ <<< "${entry}"
        if [[ "${n}" == "${name}" ]]; then
            log_err "Ya existe un remoto con nombre '${name}'"
            return 1
        fi
    done

    # Aviso no bloqueante si el directorio local no existe en este equipo
    if [[ ! -d "${local_dir}" ]]; then
        log_warn "El directorio local '${local_dir}' no existe en este equipo"
    fi

    REMOTES+=("${name}|${host}|${local_dir}|${remote_dir}|${branch}|${main_branch}|${git_remote}")
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
        IFS='|' read -r name _ _ _ _ _ <<< "${entry}"
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

# Pasos locales: merge de la rama actual a la rama principal y push a github
#   git checkout <main_branch> && git merge CURRENT_BRANCH && git tag <tag> && git checkout CURRENT_BRANCH && git push ${git_remote} <main_branch> dev && git push ${git_remote} <tag>
# El tag (opcional) se crea sobre la rama principal, apuntando al commit ya mergeado.
# Recibe: directorio local del proyecto, rama principal (main/master) y tag opcional.
deploy_local() {
    local local_dir="${1:-}"
    local main_branch="${2:-}"
    local tag="${3:-}"
    local git_remote="${4:-github}"

    # La rama principal es obligatoria y configura por remoto (formato viejo => main)
    main_branch="${main_branch:-main}"

    if [[ -z "${local_dir}" ]]; then
        log_err "Falta el directorio local del proyecto en la configuración"
        return 1
    fi
    if [[ ! -d "${local_dir}" ]]; then
        log_err "El directorio local '${local_dir}' no existe"
        return 1
    fi
    if ! git -C "${local_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_err "'${local_dir}' no es un repositorio git"
        return 1
    fi

    # Trabajar dentro del directorio local del proyecto
    cd "${local_dir}"

    if ! git show-ref --verify --quiet "refs/heads/${main_branch}"; then
        log_err "No existe la rama '${main_branch}' en ${local_dir}"
        return 1
    fi

    local current_branch
    current_branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ -z "${current_branch}" || "${current_branch}" == "HEAD" ]]; then
        log_err "No se pudo determinar la rama actual"
        return 1
    fi

    log_info "Rama actual (CURRENT_BRANCH): ${current_branch}"
    log_info "Rama principal: ${main_branch}"

    # Validar el tag antes de tocar las ramas para no dejar el repo a medias
    if [[ -n "${tag}" ]] && git rev-parse --verify "refs/tags/${tag}" >/dev/null 2>&1; then
        log_err "El tag '${tag}' ya existe"
        return 1
    fi

    log_step "git checkout ${main_branch}"
    git checkout "${main_branch}"

    log_step "git merge --no-edit ${current_branch}"
    git merge --no-edit "${current_branch}"

    if [[ -n "${tag}" ]]; then
        log_step "git tag ${tag}"
        git tag "${tag}"
    fi

    log_step "git checkout ${current_branch}"
    git checkout "${current_branch}"

    log_step "git push ${git_remote} ${main_branch} dev"
    git push ${git_remote} "${main_branch}" dev

    if [[ -n "${tag}" ]]; then
        log_step "git push ${git_remote} ${tag}"
        git push ${git_remote} "${tag}"
    fi

    if [[ -n "${tag}" ]]; then
        log_ok "Pasos locales completados: ${main_branch} actualizada, pusheada a ${git_remote} (tag: ${tag})"
    else
        log_ok "Pasos locales completados: ${main_branch} actualizada y pusheada a ${git_remote}"
    fi
}

# Actualizar un remoto (git pull + reinicio del servicio systemd)
update_remote() {
    local name="${1}"
    local host="${2}"
    local remote_dir="${3}"
    local branch="${4}"

    log_step "Actualizando ${name} (${host}:${remote_dir})..."

    # Verificar conectividad SSH
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "${host}" "true" 2>/dev/null; then
        log_err "No se puede conectar a ${host} via SSH"
        return 1
    fi

    # En el remoto: git pull + ./service.sh restart
    local cmd="
        set -euo pipefail
        cd '${remote_dir}' || { echo 'Directorio no existe'; exit 1; }
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

# Desplegar: pasos locales + actualizar un remoto específico (obligatorio)
cmd_deploy() {
    if ! command -v git >/dev/null 2>&1; then
        log_err "git no está disponible en este sistema"
        return 1
    fi

    if [[ -z "${TARGET}" ]]; then
        log_err "Debes especificar el remoto a actualizar (ej. $0 produccion)."
        return 1
    fi

    load_remotes
    if [[ ${#REMOTES[@]} -eq 0 ]]; then
        log_warn "No hay remotos configurados. Usa '$0 --add' para agregar uno."
        return 1
    fi

    # Validar que el remoto exista antes de tocar el repositorio local
    local found=false
    for entry in "${REMOTES[@]}"; do
        IFS='|' read -r name _ _ _ _ _ <<< "${entry}"
        if [[ "${name}" == "${TARGET}" ]]; then
            found=true
            break
        fi
    done
    if [[ "${found}" == false ]]; then
        log_err "No se encontró remoto '${TARGET}'"
        return 1
    fi

    local failed=0
    local success=0
    declare -A processed_dirs

    for entry in "${REMOTES[@]}"; do
        IFS='|' read -r name host local_dir remote_dir branch main_branch git_remote <<< "${entry}"

        if [[ "${name}" != "${TARGET}" ]]; then
            continue
        fi

        # Pasos locales solo una vez por combinación directorio local + rama principal
        local key="${local_dir}|${main_branch}"
        if [[ -z "${processed_dirs[${key}]:-}" ]]; then
            if ! deploy_local "${local_dir}" "${main_branch}" "${TAG}" "${git_remote}"; then
                return 1
            fi
            processed_dirs["${key}"]=1
        fi

        if update_remote "${name}" "${host}" "${remote_dir}" "${branch}"; then
            ((success++))
        else
            ((failed++))
        fi
        echo
    done

    echo -e "${CYAN}Resumen:${NC} ${success} exitoso(s), ${failed} fallido(s)"
    if [[ ${failed} -gt 0 ]]; then
        return 1
    fi
}

# Mostrar ayuda
show_help() {
    cat <<EOF
${CYAN}deploy.sh${NC} - Desplegar cambios: merge a la rama principal, push y actualizar un remoto

${BLUE}Proceso:${NC}
  1. git checkout <rama principal> (main/master, configurable)
  2. git merge <rama actual>
  3. git tag <tag> (opcional, sobre la rama principal)
  4. git checkout <rama actual>
  5. git push <remoto_git> <rama principal> dev
  6. git push <remoto_git> <tag> (si se indicó --tag)
  7. En el remoto (SSH): git pull + ./service.sh restart

${BLUE}Uso:${NC}
  $0                    Lista los remotos configurados
  $0 <nombre>           Despliega y actualiza solo el remoto especificado
  $0 --tag <tag> <nombre>  Despliega el remoto y además crea y pushea un tag al remoto git
  $0 --list             Lista los remotos configurados
  $0 --add              Agrega un remoto interactivamente
  $0 --remove <nombre>  Elimina un remoto
  $0 --inspect <nombre> Muestra detalles completos del remoto
  $0 --help             Muestra esta ayuda

${BLUE}Nota:${NC} el despliegue siempre requiere indicar el remoto a actualizar.
No existe opción para actualizar todos los remotos a la vez.

${BLUE}Archivo de configuración:${NC} ${CONFIG_FILE}
Formato: nombre|user@host|directorio_local|directorio_remoto|rama|main_branch|remoto_git

${BLUE}Ejemplo remotes.conf:${NC}
  produccion|ubuntu@192.168.1.100|/home/jose/proyectos/baileys-bridge|/home/ubuntu/baileys-bridge|main|main|github
  staging|deploy@staging.empresa.com|/home/jose/proyectos/baileys-bridge|/opt/baileys-bridge|develop|main|github

${BLUE}Requisitos:${NC}
  - Acceso SSH sin contraseña (claves SSH) a los servidores remotos
  - El directorio remoto debe ser un repositorio git con remote 'origin'
  - El usuario SSH debe tener permisos de escritura en el directorio
  - ./service.sh restart requiere permisos de root en el servidor (sudo)

${BLUE}Ejemplos:${NC}
  $0                               # Lista los remotos configurados
  $0 produccion                    # Despliega y actualiza solo 'produccion'
  $0 --tag v1.2.3 produccion       # Tag + despliegue del remoto 'produccion'
  $0 --add                         # Agrega nuevo remoto
  $0 --remove staging              # Elimina 'staging'
EOF
}

# Main
if [[ $# -eq 0 ]]; then
    cmd_list
    exit 0
fi

case "${1}" in
    --list|-l)
        cmd_list
        ;;
    --add|-a)
        cmd_add
        ;;
    --remove|-r)
        cmd_remove "${2:-}"
        ;;
    --inspect|-i)
        cmd_inspect "${2:-}"
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
