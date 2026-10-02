#!/usr/bin/env bash
# Verificación completa del proyecto: lo mismo en local (antes de abrir el PR) y en CI.
# No necesita Proxmox ni la LAN: comprueba los scripts y los snippets sin ejecutarlos.
# Tiene que acabar en error si algo falla.
set -euo pipefail
cd "$(dirname "$0")/.."

paso() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

mapfile -t scripts < <(git ls-files '*.sh' '.githooks/*')

paso "Sintaxis de los scripts de shell"
for f in "${scripts[@]}"; do bash -n "$f"; done
echo "ok (${#scripts[@]} scripts)"

# Imagen fijada: la misma versión en local y en CI. Sin Docker, el shellcheck instalado.
paso "shellcheck (avisos y errores)"
if command -v docker >/dev/null; then
  docker run --rm -v "$PWD:/m:ro" -w /m koalaman/shellcheck:v0.11.0 -S warning "${scripts[@]}"
else
  shellcheck -S warning "${scripts[@]}"
fi
echo "ok"

# Los snippets de cloud-init llevan marcadores __X__ que sustituyen los scripts: aun así,
# tienen que ser YAML válido para que cloud-init no los ignore.
paso "Snippets de cloud-init (YAML válido)"
git ls-files -z 'homelab-pve-*/snippets/*.yaml' | xargs -0 -r python3 -c '
import sys, yaml
for f in sys.argv[1:]:
    with open(f) as fh:
        doc = yaml.safe_load(fh)
    if not isinstance(doc, dict):
        sys.exit(f"{f}: no es un mapa YAML")
    print("ok", f)
'

echo
echo "check.sh: todo bien"
