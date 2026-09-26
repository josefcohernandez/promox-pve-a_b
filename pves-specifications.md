# Homelab — Especificación v1.1 (26/09/2026)

Objetivo: dos nodos Proxmox independientes. **pve-a** estable (prod, dev, backups) y **pve-b** desechable (lab Kubernetes creado y destruido por OpenTofu). Backups y NFS en un Synology DS920+.

**Cambio v1.1:** fase inicial con **todo en la LAN 192.168.130.0/24**; la VLAN de lab queda como evolución posterior (sección 9). IPs de las VMs gestionadas por **reservas DHCP en el MikroTik** sobre MACs fijas; hostname e IP de cada máquina son variables del bootstrap.

Pendiente de confirmar (no bloquea el resto): `<IP_NAS>` y el proveedor DNS público de esojfware.com (asumido Cloudflare para DNS-01).

## 1. Hardware y base

| Nodo | Hostname | CPU | RAM | Disco | Storage PVE | Papel |
|---|---|---|---|---|---|---|
| A | pve-a | i3-10110U (2c/4t) | 32 GB | 1 TB NVMe | `local-lvm` (LVM-thin) | prod, dev, pbs |
| B | pve-b | i3-10110U (2c/4t) | 24 GB | 256 GB NVMe | `local-lvm` (LVM-thin) | lab k8s |
| NAS | synology (DS920+) | — | — | 900 GB libres | — | PBS datastore, NFS lab |

- Proxmox VE 9.2, **sin clúster** (confirmado: no hay corosync.conf). No hay QDevice.
- Discos de VM: `local-lvm`, `discard=on`, `ssd=1`, VirtIO SCSI single, `iothread=1`.
- `local` con contenido `snippets` en ambos nodos; en pve-b además `import` (imágenes cloud que descarga OpenTofu).
- SO de todas las VMs: **Ubuntu Server 26.04 LTS** imagen cloud + cloud-init; `qemu-guest-agent` instalado por cloud-init.
- Wi-Fi de los mini PC deshabilitada. `eth0` → `vmbr0` (VLAN-aware, sin uso de tags por ahora); `eth1` reservada.

## 2. Red (fase inicial: una sola red)

Router: MikroTik RB3011UiAS, router de la LAN, detrás del pfSense del ISP (doble NAT). DHCP y DNS los sirve el MikroTik.

| Red | Subred | Gateway / DNS | Dominio | DHCP |
|---|---|---|---|---|
| LAN | 192.168.130.0/24 | 192.168.130.1 | `home.esojfware.com` | pool del MikroTik; reservar .200–.250 fuera del pool para MetalLB |

- Nodos con IP fija en `/etc/network/interfaces`: pve-a .11, pve-b .12.
- VMs y LXC: **DHCP con reserva por MAC** en el MikroTik (o IP fija por cloud-init si se rellena la variable). MACs fijas y predecibles `BC:24:11:A0:<vmid hex>:<nic>`: prod `…:64:00`, dev `…:6E:00`, pbs `…:78:00`; las de k8s (200–202) las fija el repo de tofu con el mismo esquema (`…:C8:00`, `…:C9:00`, `…:CA:00`).
- Nombres: entradas DNS estáticas en el MikroTik junto a cada reserva (`prod.home.esojfware.com`, etc.); regex `.*\.lab\.esojfware\.com` → IP de Traefik en MetalLB.
- Certificados: cert-manager con Let's Encrypt **DNS-01**; wildcard `*.lab.esojfware.com` para el clúster y `*.home.esojfware.com` para prod.

### Direccionamiento de referencia

| Máquina | IP prevista (reserva DHCP) |
|---|---|
| mikrotik | 192.168.130.1 |
| synology | `<IP_NAS>` |
| pve-a / pve-b | .11 / .12 (fijas) |
| prod / dev / pbs | .100 / .110 / .120 |
| k8s-cp-1 / k8s-w-1 / k8s-w-2 | .21 / .22 / .23 |
| MetalLB (Traefik en .200) | .200–.250 |

## 3. Inventario de máquinas

### Nodo A (bootstrap `pve-a.sh`, una vez)

| VMID | Nombre por defecto | Tipo | vCPU | RAM | Disco | Función |
|---|---|---|---|---|---|---|
| 9000 | ubuntu2604-cloudinit | plantilla | – | – | ~4 GB | base para prod y dev |
| 100 | prod | VM | 2 | 8 GB fijos | 250 GB | Docker Compose: servicios de casa, MinIO (estado tofu), Harbor (fase 5) |
| 110 | dev | VM | 2 | 12 GB fijos | 200 GB | OpenTofu, kubectl 1.36, Helm, Argo CD CLI, mc, k9s, Docker, Git |
| 120 | pbs | LXC unprivileged (Debian 13) | 1 | 2 GB | 8 GB rootfs | Proxmox Backup Server; datastore en NFS del NAS por bind mount |

Hostname, IP y MAC de cada una son variables (`X_HOSTNAME`, `X_IP`, `X_MAC`) con los defaults anteriores. RAM comprometida: 22 de 32 GB.

### Nodo B (`pve-b.sh` solo limpia y prepara; todo lo crea el repo de OpenTofu)

| VMID | Nombre | Tipo | vCPU | RAM min/max | Disco | Función |
|---|---|---|---|---|---|---|
| 9001 | ubuntu2604-cloudinit | plantilla | – | – | ~4 GB | la crea OpenTofu (`download_file` + template) |
| 200 | k8s-cp-1 | VM | 2 | 2/4 GB | 40 GB | rke2 server (etcd + API), taint `CriticalAddonsOnly` |
| 201 | k8s-w-1 | VM | 2 | 4/8 GB | 80 GB | rke2 agent + Longhorn |
| 202 | k8s-w-2 | VM | 2 | 4/8 GB | 80 GB | rke2 agent + Longhorn |

RAM máx.: 20 de 24 GB. Disco: 204 GB thin de 256.

## 4. Kubernetes

| Componente | Decisión |
|---|---|
| Distribución | **RKE2 v1.36.x** (Rancher 2.15 certifica 1.34–1.36) |
| Instalación | **cloud-init** generado por OpenTofu: instala rke2 y escribe `/etc/rancher/rke2/config.yaml` |
| CNI | Canal (por defecto) |
| Ingress | **Traefik** (por defecto en 1.36), Service LoadBalancer en 192.168.130.200 |
| LoadBalancer | MetalLB L2, pool 192.168.130.200–.250 |
| Storage | **Longhorn** por defecto, réplica 2, backup target NFS del NAS; StorageClass NFS adicional para RWX |
| Certificados | cert-manager + DNS-01 |
| Gestión | **Rancher 2.15** por Helm en el propio clúster (`rancher.lab.esojfware.com`) |
| GitOps | **Argo CD**; bootstrap (MetalLB, cert-manager, Rancher) por Helm, el resto desde Git |
| Actualizaciones | RKE2 vía Rancher (system-upgrade-controller); cambios estructurales recreando con tofu |

## 5. IaC

- **OpenTofu** + provider `bpg/proxmox` (≥ 0.114) desde dev contra la API de pve-b (token `terraform@pve`, SSH para snippets). Repo aparte (`homelab-tofu`).
- Estado: backend S3 en **MinIO de prod**, versionado; `tofu state pull` a local antes de cada `destroy`.
- Alcance: plantilla 9001 y VMs 200–202, salida `kubeconfig`.
- Bootstrap de los nodos en scripts bash versionados: `homelab-pve-a` (wipe, host, template, prod, dev, pbs, macs) y `homelab-pve-b` (wipe, host, clean).

## 6. Backups y NAS

Synology DS920+ (900 GB libres). NFS activado (NFSv4.1):

| Carpeta compartida | Cuota | Uso | Permisos NFS |
|---|---|---|---|
| `pbs` | 500 GB | datastore PBS | 192.168.130.11: RW, "map all users to admin" |
| `k8s-nfs` | 200 GB | Longhorn backup target + volúmenes RWX | 192.168.130.0/24: RW, map all to admin |
| `tofu-state-mirror` | 10 GB | copia diaria del bucket MinIO (`mc mirror` desde prod) | prod: RW |

- PBS como LXC unprivileged en pve-a; pve-a monta `<IP_NAS>:/volume1/pbs` en `/mnt/pbs` y lo pasa por bind mount. El storage `nas-pbs` en Proxmox se registra por IP: la de PBS debe ser reserva fija.
- Job diario 03:00 de prod y dev (snapshot + guest agent), retención **7/4/3**, prune job y GC en PBS, verify semanal.
- El lab k8s no se respalda como VMs: datos en Longhorn → NFS; definición en Git.
- Snapshots de Synology sobre `pbs` y `k8s-nfs`: semanal, retener 4.

## 7. Fases de montaje

0. MikroTik: reservas DHCP + DNS estático para las MACs conocidas; rango .200–.250 fuera del pool. Synology: NFS, carpetas y permisos.
1. pve-a: `wipe` → `host` → reboot → `all`. Primer backup verificado.
2. pve-b: `wipe` → `host` → reboot → `clean`.
3. Desde dev: repo tofu → `tofu apply` → clúster RKE2 con kubeconfig.
4. Bootstrap del clúster: MetalLB, cert-manager, Traefik LB fijo, Longhorn, Rancher, Argo CD. Después, GitOps.
5. Harbor en prod; migración de servicios de casa y stack ENS al lab.

## 8. Decisiones descartadas y por qué

- Clúster Proxmox / HA / QDevice: sin storage compartido ni migración; B debe poder apagarse.
- RKE2 v1.37: no existe; ingress-nginx: EOL marzo 2026.
- DNS/DHCP en prod: lo hace el router.
- OpenTofu para pve-a: dependencia circular (tofu corre en dev, estado en prod); scripts bash reproducibles en su lugar.
- Ansible para RKE2: innecesario mientras el lab sea desechable.
- PBS en Raspberry: sin paquetes oficiales ARM. Lab en la máquina de 32 GB: el disco de 256 GB no cabe para prod+dev.
- Tercer worker: sin RAM suficiente en B con margen.

## 9. Evolución prevista: VLAN de lab

Cuando se quiera aislar el lab: VLAN 20 (10.20.0.0/24, gw MikroTik, dominio `lab.esojfware.com`, DHCP .100–.199, MetalLB .200–.250), puertos hacia los nodos en trunk, `tag=20` en las VMs 200–202 y segunda interfaz en dev (sin ruta por defecto por esa pata), firewall LAB→LAN limitado a NAS y prod. `vmbr0` ya es VLAN-aware, así que no hay que tocar la red de los hosts.
