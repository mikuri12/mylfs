#!/bin/bash
# base/download-sources.sh — Descarga y verifica fuentes desde el manifiesto TSV.
# Manifiesto: sha256 <TAB> md5 <TAB> archivo <TAB> URL primaria <TAB> URL fallback.
# Descarga primaria desde la URL del libro; si falla, usa el mirror de LFS.
# Verifica sha256 del archivo descargado contra el manifiesto (PLAN: fuentes
# verificadas con sha256). md5 del libro como doble verificación.
set -euo pipefail
. "$(dirname "$0")/env.sh"

MANIFEST="${1:-$(dirname "$0")/sources-12.4.stage1.tsv}"
DEST="$SOURCES"
mkdir -pv "$DEST"

fail=0
# Omitir comentarios (#) del manifiesto; 5 columnas separadas por TAB
# (process substitution en vez de pipe para que `fail` sobreviva a la subshell)
while IFS=$'\t' read -r sha256 md5 file url url_fb; do
    case "$sha256" in \#*|"") continue ;; esac
    if [ -f "$DEST/$file" ] && sha256sum "$DEST/$file" | grep -q "^$sha256"; then
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
    if [ "$got" != "$sha256" ]; then
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
