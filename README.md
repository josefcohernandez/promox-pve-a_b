# promox-pve-a_b

Scripts de preparación de los dos nodos Proxmox VE 9 del homelab, a partir de la especificación
[pves-specifications.md](pves-specifications.md):

- [`homelab-pve-a/`](homelab-pve-a/README.md): nodo estable. Plantilla Ubuntu 26.04 cloud-init,
  VM prod (100), VM dev (110) y LXC con Proxmox Backup Server (120) sobre NFS del Synology.
- `homelab-pve-b/`: nodo desechable para el lab de Kubernetes. Solo prepara el host y el
  usuario/token que usa OpenTofu; las VMs las crea OpenTofu desde dev.

Cada script se copia al nodo y se ejecuta como root allí (ver el README de cada carpeta y la
cabecera de cada script).

## Desarrollo

```bash
scripts/check.sh      # bash -n, shellcheck y YAML de los snippets: lo mismo que la CI
```

Se trabaja con la metodología común: una issue → `flujo abrir <n>` → PR → `flujo cerrar`.

## Versiones

Ver [CHANGELOG.md](CHANGELOG.md). Se publican con `flujo publicar X.Y.Z`.
