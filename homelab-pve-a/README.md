# pve-a — bootstrap

Crea desde cero el nodo estable del homelab: plantilla 9000, VM 100 `prod`, VM 110 `dev` y LXC 120 `pbs`.
Referencia: `homelab-especificacion.md` en el proyecto.

## Antes de ejecutar

1. MikroTik: VLAN 20 creada, puerto de pve-a en trunk (LAN untagged + VLAN 20 tagged), DHCP de LAN sin usar .11 .100 .110 .120.
2. Synology: NFS activado (NFSv4.1), carpeta compartida `pbs` con permiso NFS para `192.168.130.11` (RW, "map all users to admin").
3. Tener la clave pública SSH a mano.

## Uso

```bash
scp -r homelab-pve-a root@<ip-actual-del-nodo>:/root/
ssh root@<ip-actual-del-nodo>
cd /root/homelab-pve-a
cp pve-a.env.example pve-a.env && nano pve-a.env     # SSH_PUBKEY, NAS_IP, PBS_ROOT_PASSWORD

./pve-a.sh wipe     # pide escribir el hostname y BORRAR; deja el nodo vacío
./pve-a.sh host     # hostname pve-a, vmbr0 VLAN-aware con .11, snippets, NFS
reboot
ssh root@192.168.130.11
cd /root/homelab-pve-a && ./pve-a.sh all
```

`all` tarda 10–20 min: descarga la imagen (824 MB), clona, y cloud-init instala Docker en prod y el tooling en dev.
Cada etapa (`template`, `prod`, `dev`, `pbs`) se puede relanzar sola: destruye y recrea solo esa máquina.

## Comprobaciones al terminar

```bash
qm list; pct list
ssh jose@192.168.130.100 'docker ps; cat /var/log/cloud-init-output.log | tail -3'
ssh jose@192.168.130.110 'tofu version; kubectl version --client; helm version; ip -br a'   # debe ver eth0 .110 y eth1 10.20.0.10
pvesm status                       # nas-pbs activo
vzdump 100 --storage nas-pbs --mode snapshot    # primer backup manual, luego el job diario a las 03:00
```

PBS: https://192.168.130.120:8007 (root@pam, la contraseña de `pve-a.env`).

## Qué hace `wipe`

Borra jobs de backup, todas las VMs y LXC (con sus discos), discos huérfanos de `local-lvm`, storages PBS y snippets.
No toca `local` (ISOs, plantillas LXC descargadas) ni la configuración de red. Pide dos confirmaciones.
