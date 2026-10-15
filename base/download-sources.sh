#!/bin/bash
# base/download-sources.sh — Descarga y verifica fuentes desde un manifiesto TSV.
#
# Formatos de manifiesto soportados (columnas separadas por TAB, # = comentario):
#   5 col: sha256, md5(libro), archivo, URL primaria, URL fallback   (etapas 1-2)
#   4 col: sha256, archivo, URL primaria, URL fallback               (etapas 3+)
#   5 col: sha256, archivo, URL, fuente-del-checksum (texto libre)   (extras)
#
# La detección es por conteo de columnas de CADA fila (los manifiestos de
# extras llevan texto en la última columna, no URL). Verificación SIEMPRE sha256.
# El bucle usa process substitution para que `fail` sobreviva (no pipe → subshell).
set -euo pipefail
. "$(dirname "$0")/env.sh"

MANIFEST="${1:-$(dirname "$0")/sources-12.4.stage1.tsv}"
DEST="$SOURCES"
mkdir -pv "$DEST"

fail=0
while IFS=$'\t' read -r c1 c2 c3 c4 c5; do
    case "$c1" in \#*|"") continue ;; esac
    # Detectar formato por conteo de columnas
    if [ -n "$c5" ]; then
        # 5 col con md5 (etapas 1-2): sha256 md5 file url url_fb
        file=$c3; url=$c4; url_fb=$c5
    elif [ -n "$c4" ]; then
        # 4 col (etapas 3+): sha256 file url url_fb — PERO los extras usan
        # sha256 file url "fuente del checksum" (texto, no URL).
        # Heurística: la 4a columna es URL si empieza con http/ftp.
        file=$c2; url=$c3
        case "$c4" in http*|ftp*) url_fb=$c4 ;; *) url_fb="" ;; esac
    else
        echo "FILA INVÁLIDA (menos de 3 columnas): $c1"; fail=1; continue
    fi
    [ -n "$file" ] || continue

    if [ -f "$DEST/$file" ] && [ "$(sha256sum "$DEST/$file" | cut -d' ' -f1)" = "$c1" ]; then
        echo "OK (caché): $file"
        continue
    fi
    ok=0
    for u in "$url" "$url_fb"; do
        [ -n "$u" ] || continue
        echo ">> $file — $u"
        if curl -fsSL --retry 3 --connect-timeout 30 -o "$DEST/$file.part" "$u"; then
            ok=1
            break
        fi
        rm -f "$DEST/$file.part"
        echo "   falló $u, probando fallback…"
    done
    if [ $ok -ne 1 ]; then
        echo "FALLO: $file — ninguna URL sirvió"
        fail=1
        continue
    fi
    got=$(sha256sum "$DEST/$file.part" | cut -d' ' -f1)
    if [ "$got" != "$c1" ]; then
        echo "SHA256 NO COINCIDE: $file (got $got)"
        rm -f "$DEST/$file.part"
        fail=1
        continue
    fi
    mv -f "$DEST/$file.part" "$DEST/$file"
    echo "OK: $file"
done < <(grep -v '^#' "$MANIFEST")
[ $fail -eq 0 ] || { echo "Hubo fallas de descarga/verificación"; exit 1; }
echo "== manifiesto completo y verificado =="
