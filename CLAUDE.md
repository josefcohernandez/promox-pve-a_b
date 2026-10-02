# promox-pve-a_b

<!-- Este fichero se carga en cada sesión: solo lo que Claude no puede deducir del código.
     Menos de 200 líneas. Cada línea pasa la prueba "si la quito, ¿se equivocaría?". -->

Proceso: metodología común (`~/.claude/metodologia/METODOLOGIA.md`). Todo entra por PR desde un
worktree (`flujo abrir <issue>`), con título `tipo: descripción` en español.

## Qué es

Scripts bash que preparan desde cero los dos nodos Proxmox VE 9 del homelab: `homelab-pve-a/`
(nodo estable: plantilla 9000, VM prod 100, VM dev 110, LXC PBS 120) y `homelab-pve-b/` (nodo
desechable para el lab de Kubernetes; solo host y token de OpenTofu). La especificación de
referencia es [pves-specifications.md](pves-specifications.md).

## Comandos

- Verificación completa (la misma que la CI): `scripts/check.sh` (bash -n, shellcheck y YAML de
  los snippets). No ejecuta nada contra Proxmox.

## Gotchas

- Los scripts se ejecutan como root **en el nodo**, nunca desde aquí: `wipe` borra todas las VMs,
  y relanzar `prod`/`dev` destruye la VM con sus discos. Claude no los ejecuta.
- Configuración en `pve-a.env` / `pve-b.env` (copias de los `.env.example`, con contraseñas): no
  se versionan. Una variable nueva va en el `.env.example` y en *Variables nuevas* del CHANGELOG.
- Los snippets de `homelab-pve-a/snippets/` son cloud-init con marcadores `__X__` que sustituye
  `pve-a.sh`: un marcador nuevo se añade en los dos lados.
- Las MACs son fijas y derivadas del VMID (`BC:24:11:A0:<vmid>:<nic>`): hay reservas DHCP en el
  MikroTik que dependen de ellas.
- En el CHANGELOG, *Migraciones* explica qué hacer a mano en un nodo ya montado (`qm set`, etc.).

## Decisiones vigentes

Las decisiones de diseño están en [pves-specifications.md](pves-specifications.md); las nuevas
de peso, en `docs/adr/`.
