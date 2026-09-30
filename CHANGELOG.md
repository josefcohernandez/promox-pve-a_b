# Changelog

## v0.1.0 — 2026-09-30

### Añadido
- `VM_PASSWORD`: password de `VM_USER` para entrar por la consola de Proxmox en prod y dev (hash SHA-512 en los snippets; SSH sigue solo con clave).
- README de pve-a: sección *Pendiente* con las tareas manuales (primer backup y restauración, reserva DHCP del PBS, snapshots Synology, copia fuera del NAS, espejo del estado tofu).

### Cambiado
- Plantilla 9000 con pantalla gráfica (`--vga std`): la consola noVNC de Proxmox funciona. Se mantiene `serial0` para xterm.js.
- `./pve-a.sh pbs` reutiliza el datastore del NAS si ya tiene copias, en vez de fallar.
- README: aviso de que relanzar `prod`/`dev` destruye la VM con sus discos.

### Migraciones
- VMs creadas con v0.0.1: no hace falta recrearlas. `qm set <id> --vga std` + `qm shutdown`/`qm start`, y `sudo passwd <VM_USER>` dentro de cada VM.

### Variables nuevas
- `VM_PASSWORD` (**obligatoria**, sin valor por defecto): el script no arranca si falta o vale `cambiame`. Añadirla a `pve-a.env`.

## v0.0.1 — 2026-09-26

- Versión inicial sin probar.
