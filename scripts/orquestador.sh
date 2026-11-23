#!/bin/bash

set -Eeuo pipefail

DIRECTORIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG="$DIRECTORIO/operaciones.log"

ERRORES=0
OPCIONES_SELECCIONADAS=()
EJECUTAR_TODAS=0

touch "$LOG"

manejar_error() {
    local codigo="$1"
    local linea="$2"
    local comando="$3"
    local mensaje

    mensaje="ERROR: Código $codigo. Línea $linea. Comando: $comando"

    trap - ERR

    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" >> "$LOG" 2>/dev/null || true

    logger -t orquestador_noc "$mensaje" || true

    echo "$mensaje"

    exit "$((codigo == 0 ? 1 : codigo))"
}

trap 'manejar_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

registrarOperacion() {
    local mensaje="$1"

    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" >> "$LOG"
    logger -t orquestador_noc "$mensaje" || true
}

registrarOperacion "INICIO DEL ORQUESTADOR"

ejecutarScript() {
    local nombre="$1"
    local script="$DIRECTORIO/$2"
    local codigo

    registrarOperacion "INICIO: $nombre"

    if [[ ! -f "$script" ]]; then
        registrarOperacion "ERROR: No existe el script $script"
        ERRORES=$((ERRORES + 1))
        registrarOperacion "FIN: $nombre - FALLIDO"
        return 0
    fi

    if [[ ! -x "$script" ]]; then
        registrarOperacion "ERROR: El script $script no es ejecutable"
        ERRORES=$((ERRORES + 1))
        registrarOperacion "FIN: $nombre - FALLIDO"
        return 0
    fi

    if "$script"; then
        registrarOperacion "FIN: $nombre - EXITOSO"
    else
        codigo=$?

        registrarOperacion "ERROR: $nombre terminó con código $codigo"
        registrarOperacion "FIN: $nombre - FALLIDO"

        ERRORES=$((ERRORES + 1))
    fi
}

monitoreo() {
    ejecutarScript "MONITOREO" "monitoreo.sh"
}

analisisLogs() {
    ejecutarScript "ANALISIS DE LOGS" "analisis_logs.sh"
}

respaldo() {
    ejecutarScript "RESPALDO" "respaldo_versionado.sh"
}

auditoria() {
    ejecutarScript "AUDITORIA" "auditoria.sh"
}

ayuda() {
    echo "====================================="
    echo "          ORQUESTADOR NOC"
    echo "====================================="
    echo "Uso: ./orquestador.sh [opciones]"
    echo ""
    echo "Opciones:"
    echo "  -m    Ejecutar monitoreo"
    echo "  -l    Ejecutar análisis de logs"
    echo "  -r    Ejecutar respaldo"
    echo "  -a    Ejecutar auditoría"
    echo "  -t    Ejecutar todas las operaciones"
    echo "  -h    Mostrar ayuda"
    echo ""
    echo "Ejemplos:"
    echo "  ./orquestador.sh -m"
    echo "  ./orquestador.sh -l -r"
    echo "  ./orquestador.sh -t"
    echo "====================================="
}

while getopts ":mlrath" opcion; do
    case "$opcion" in
        m|l|r|a)
            if [[ ! " ${OPCIONES_SELECCIONADAS[*]} " =~ " $opcion " ]]; then
                OPCIONES_SELECCIONADAS+=("$opcion")
            fi
            ;;
        t)
            EJECUTAR_TODAS=1
            ;;
        h)
            ayuda
            exit 0
            ;;
        :)
            echo "ERROR: La opción -$OPTARG requiere un argumento."
            ayuda
            exit 1
            ;;
        \?)
            echo "ERROR: Opción no válida: -$OPTARG"
            ayuda
            exit 1
            ;;
    esac
done

shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
    echo "ERROR: Argumentos no reconocidos: $*"
    ayuda
    exit 1
fi

if [[ "$EJECUTAR_TODAS" -eq 1 ]]; then
    OPCIONES_SELECCIONADAS=("m" "l" "r" "a")
fi

if [[ ${#OPCIONES_SELECCIONADAS[@]} -eq 0 ]]; then
    echo "ERROR: Debes seleccionar una operación."
    ayuda
    exit 1
fi

registrarOperacion "INICIO DE EJECUCION DE OPERACIONES"

for opcion in "${OPCIONES_SELECCIONADAS[@]}"; do
    case "$opcion" in
        m)
            monitoreo
            ;;
        l)
            analisisLogs
            ;;
        r)
            respaldo
            ;;
        a)
            auditoria
            ;;
    esac
done

if [[ "$ERRORES" -eq 0 ]]; then
    registrarOperacion "FIN DEL ORQUESTADOR - TODAS LAS OPERACIONES EXITOSAS"
    echo "Todas las operaciones finalizaron correctamente."
    exit 0
else
    registrarOperacion "FIN DEL ORQUESTADOR - OPERACIONES FALLIDAS: $ERRORES"
    echo "El orquestador terminó con $ERRORES operación(es) fallida(s)."
    exit 1
fi
