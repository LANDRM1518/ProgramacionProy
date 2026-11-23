#!/bin/bash

set -Eeuo pipefail

DIRECTORIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASTION_USER="bastion"
BASTION_HOST="127.0.0.1"
BASTION_PORT="2222"
SSH_KEY="$HOME/.ssh/id_ed25519"

BASTION="$BASTION_USER@$BASTION_HOST"

RUTA_WEB="/mnt/web"
RUTA_ARCHIVOS="/mnt/archivos"
RUTA_LOGS="/var/log"

BACKUP_DIR="$DIRECTORIO/respaldos"
FECHA="$(date '+%Y%m%d_%H%M%S')"
SNAPSHOT="$BACKUP_DIR/respaldo_$FECHA"
STAGING="$BACKUP_DIR/.staging_$FECHA"

AUDITORIA="$BACKUP_DIR/auditoria.log"
ERROR_LOG="$DIRECTORIO/errores_respaldo.log"

GIT_USER_NAME="NOC Backup"
GIT_USER_EMAIL="noc-backup@localhost"

mkdir -p "$BACKUP_DIR"

touch "$AUDITORIA" "$ERROR_LOG"

manejar_error() {
    local codigo="$1"
    local linea="$2"
    local comando="$3"
    local mensaje

    mensaje="ERROR: Código $codigo. Línea $linea. Comando: $comando"

    trap - ERR

    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" >> "$ERROR_LOG" 2>/dev/null || true

    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" >> "$AUDITORIA" 2>/dev/null || true

    logger -t respaldo_versionado "$mensaje" || true

    rm -rf -- "$STAGING" 2>/dev/null || true

    echo "$mensaje"
    echo "El respaldo no pudo completarse."

    exit 1
}

trap 'manejar_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

registrarAuditoria() {
    local mensaje="$1"

    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" >> "$AUDITORIA"

    logger -t respaldo_versionado "$mensaje" || true

    echo "$mensaje"
}

registrarAuditoria "INICIO DEL RESPALDO: $FECHA"

for comando in ssh scp tar git sha256sum grep; do
    if ! command -v "$comando" >/dev/null 2>&1; then
        manejar_error 1 "$LINENO" "Dependencia no instalada: $comando"
    fi
done

registrarAuditoria "Dependencias verificadas"

if [[ ! -f "$SSH_KEY" || ! -r "$SSH_KEY" ]]; then
    manejar_error 1 "$LINENO" "Clave SSH no encontrada o sin permisos de lectura"
fi

registrarAuditoria "Clave SSH verificada"

SSH_OPTS=(
    -i "$SSH_KEY"
    -p "$BASTION_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=15
    -o StrictHostKeyChecking=accept-new
)

SCP_OPTS=(
    -i "$SSH_KEY"
    -P "$BASTION_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=15
    -o StrictHostKeyChecking=accept-new
)

mkdir -p "$SNAPSHOT"
mkdir -p "$STAGING/volumen_web"
mkdir -p "$STAGING/volumen_archivos"
mkdir -p "$STAGING/logs"

registrarAuditoria "Directorios locales preparados"
registrarAuditoria "BASTION: $BASTION"
registrarAuditoria "PUERTO: $BASTION_PORT"

registrarAuditoria "Verificando conexion SSH"

ssh "${SSH_OPTS[@]}" "$BASTION" \
    "test -d '$RUTA_WEB' &&
     test -r '$RUTA_WEB' &&
     test -d '$RUTA_ARCHIVOS' &&
     test -r '$RUTA_ARCHIVOS' &&
     test -d '$RUTA_LOGS' &&
     test -r '$RUTA_LOGS'"

registrarAuditoria "Conexion SSH establecida correctamente"

copiarConSCP() {
    local origen="$1"
    local destino="$2"
    local nombre="$3"

    registrarAuditoria "INICIO: Copia de $nombre"

    scp "${SCP_OPTS[@]}" -r -p "$BASTION:$origen/." "$destino/"

    registrarAuditoria "FIN: Copia de $nombre"
}

copiarConSCP "$RUTA_WEB" "$STAGING/volumen_web" "volumen_web"

copiarConSCP "$RUTA_ARCHIVOS" "$STAGING/volumen_archivos" "volumen_archivos"

copiarConSCP "$RUTA_LOGS" "$STAGING/logs" "logs del sistema"

registrarAuditoria "INICIO: Compresion con TAR"

tar -czf "$SNAPSHOT/volumen_web.tar.gz" -C "$STAGING" volumen_web

tar -czf "$SNAPSHOT/volumen_archivos.tar.gz" -C "$STAGING" volumen_archivos

tar -czf "$SNAPSHOT/logs.tar.gz" -C "$STAGING" logs

registrarAuditoria "FIN: Compresion con TAR"

registrarAuditoria "INICIO: Verificacion de archivos TAR"

for archivo in "$SNAPSHOT"/*.tar.gz; do

    if tar -tzf "$archivo" >/dev/null 2>&1; then
        registrarAuditoria "TAR valido: ${archivo##*/}"
    else
        manejar_error 1 "$LINENO" "Archivo TAR dañado: $archivo"
    fi

done

registrarAuditoria "FIN: Verificacion TAR"

registrarAuditoria "INICIO: Generacion de hashes SHA-256"

(
    cd "$SNAPSHOT"
    sha256sum ./*.tar.gz > SHA256SUMS
)

registrarAuditoria "Hashes SHA-256 generados"

(
    cd "$SNAPSHOT"
    sha256sum -c SHA256SUMS
)

registrarAuditoria "Integridad SHA-256 verificada"

rm -rf -- "$STAGING"

registrarAuditoria "Directorio temporal eliminado"

if [[ ! -d "$BACKUP_DIR/.git" ]]; then
    git -C "$BACKUP_DIR" init
    registrarAuditoria "Repositorio Git inicializado"
else
    registrarAuditoria "Repositorio Git existente"
fi

git -C "$BACKUP_DIR" config user.name "$GIT_USER_NAME"
git -C "$BACKUP_DIR" config user.email "$GIT_USER_EMAIL"

registrarAuditoria "Configuracion local de Git completada"

MENSAJE_COMMIT="Respaldo Docker Bastion $FECHA"

registrarAuditoria "Preparando commit: $MENSAJE_COMMIT"

git -C "$BACKUP_DIR" add -- "respaldo_$FECHA" "auditoria.log"

git -C "$BACKUP_DIR" commit -m "$MENSAJE_COMMIT"

if git -C "$BACKUP_DIR" log -1 --format='%s' |grep -Fxq "$MENSAJE_COMMIT"; then
    registrarAuditoria "Commit verificado correctamente"

else
    manejar_error 1 "$LINENO" "No se pudo verificar el commit"
fi

registrarAuditoria "RESPALDO COMPLETADO EXITOSAMENTE"
registrarAuditoria "FIN DEL RESPALDO: $FECHA"

git -C "$BACKUP_DIR" add -- auditoria.log
git -C "$BACKUP_DIR" commit --amend --no-edit

if ! git -C "$BACKUP_DIR" log -1 --format='%s' | grep -Fxq "$MENSAJE_COMMIT"; then
    manejar_error 1 "$LINENO" "Error al verificar el commit final"
fi

echo ""
echo "=============================================="
echo "          RESPALDO COMPLETADO"
echo "=============================================="
echo "Bastion: $BASTION"
echo "Puerto: $BASTION_PORT"
echo "Destino: $SNAPSHOT"
echo "Formato: TAR.GZ"
echo "Integridad: SHA-256 verificada"
echo "Versionado: Git"
echo "Auditoria: $AUDITORIA"
echo "Errores: $ERROR_LOG"
echo "Commit: $MENSAJE_COMMIT"
echo "=============================================="

exit 0
