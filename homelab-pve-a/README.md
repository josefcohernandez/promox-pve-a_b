# pve-a — bootstrap

Crea desde cero el nodo estable del homelab: plantilla 9000, VM 100 (prod), VM 110 (dev) y LXC 120 (pbs).
Referencia: `homelab-especificacion.md` en el proyecto.

## Antes de ejecutar

1. MikroTik: reservas DHCP para las MACs de abajo si quieres IPs fijas desde el router (opcional).
2. Synology: NFS activado (NFSv4.1), carpeta compartida `pbs` con permiso NFS para `192.168.130.11` (RW, "map all users to admin").
3. Clave pública SSH a mano.

## IPs, hostnames y MACs

En `pve-a.env`, por máquina: `X_HOSTNAME` (vacío = prod/dev/pbs), `X_IP` (vacío = DHCP; con valor = IP fija por cloud-init)
y `X_MAC` (vacío = MAC fija derivada del VMID, `BC:24:11:A0:<vmid>:<nic>`). Como las MACs son predecibles, puedes crear las
reservas DHCP en el MikroTik **antes** de ejecutar el script (`./pve-a.sh macs` las muestra sin crear nada) y sobreviven a recrear las VMs.

| Máquina | MAC por defecto |
|---|---|
| prod (100) LAN | BC:24:11:A0:64:00 |
| dev (110) LAN | BC:24:11:A0:6E:00 |
| pbs (120) LAN | BC:24:11:A0:78:00 |

## Uso

```bash
scp -r homelab-pve-a root@<ip-actual-del-nodo>:/root/ && ssh root@<ip-actual-del-nodo>
cd /root/homelab-pve-a
cp pve-a.env.example pve-a.env && nano pve-a.env     # SSH_PUBKEY, VM_PASSWORD, NAS_IP, PBS_ROOT_PASSWORD (+ IPs/hostnames si quieres)

./pve-a.sh wipe     # pide escribir el hostname y BORRAR; deja el nodo vacío
./pve-a.sh host     # hostname pve-a, vmbr0 VLAN-aware con .11, snippets, NFS
reboot
ssh root@192.168.130.11
cd /root/homelab-pve-a && ./pve-a.sh all
```

`all` tarda 10–20 min: descarga la imagen (824 MB), clona, y cloud-init instala Docker en prod y el tooling en dev.
Al final imprime las IPs que ha obtenido cada máquina (vía guest agent) y las MACs.
Cada etapa (`template`, `prod`, `dev`, `pbs`) se puede relanzar sola: destruye y recrea solo esa máquina.
**Ojo:** `prod` y `dev` destruyen la VM con sus discos (se pierde todo lo que haya dentro). `pbs` sí conserva las copias:
el datastore vive en el NAS y, si ya existe, se reutiliza.

Si PBS va por DHCP, el script descubre su IP y registra el storage `nas-pbs` con ella: reserva esa IP en el router,
porque Proxmox guarda la IP, no el nombre.

## Comprobaciones al terminar

```bash
qm list; pct list
ssh <VM_USER>@<ip-prod> 'docker ps; tail -3 /var/log/cloud-init-output.log'
ssh <VM_USER>@<ip-dev>  'tofu version; kubectl version --client; helm version; ip -br a'
pvesm status                                   # nas-pbs activo
vzdump 100 --storage nas-pbs --mode snapshot   # primer backup manual; luego el job diario a las 03:00
```

PBS: `https://<ip-pbs>:8007` (root@pam, la contraseña de `pve-a.env`).

## Qué hace `wipe`

Borra jobs de backup, todas las VMs y LXC (con sus discos), discos huérfanos de `local-lvm`, storages PBS y snippets.
No toca `local` (ISOs, plantillas LXC descargadas) ni la configuración de red. Pide dos confirmaciones.
