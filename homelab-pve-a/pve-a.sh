#!/usr/bin/env bash
# Bootstrap del nodo pve-a (Proxmox VE 9). Ejecutar como root EN EL NODO.
#
#   ./pve-a.sh wipe      -> borra TODAS las VMs/LXC, discos huérfanos, jobs de backup y storages PBS
#   ./pve-a.sh host      -> hostname, red (vmbr0 VLAN-aware, IP fija), snippets, NFS del NAS  (REINICIAR después)
#   ./pve-a.sh template  -> plantilla 9000 ubuntu2604-cloudinit
#   ./pve-a.sh prod      -> VM 100
#   ./pve-a.sh dev       -> VM 110
#   ./pve-a.sh pbs       -> LXC 120 con PBS, datastore en NFS, storage en PVE y job de backup
#   ./pve-a.sh all       -> template + prod + dev + pbs   (tras el reinicio de 'host')
#   ./pve-a.sh macs      -> muestra las MACs de cada máquina (para reservas DHCP en el MikroTik)
#
# Orden la primera vez:  wipe -> host -> reboot -> all
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HERE}/pve-a.env"
[[ -f "$ENV_FILE" ]] || { echo "Falta ${ENV_FILE} (copia pve-a.env.example)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
for v in SSH_PUBKEY VM_USER NAS_IP PBS_ROOT_PASSWORD NODE_NAME NODE_IP LAN_GW STORAGE; do
  [[ -n "${!v:-}" ]] || { echo "Variable $v vacía en pve-a.env"; exit 1; }
done
[[ "$NAS_IP" != *X* ]] || { echo "NAS_IP sigue con el valor de ejemplo"; exit 1; }
[[ "$PBS_ROOT_PASSWORD" != "cambiame" ]] || { echo "Cambia PBS_ROOT_PASSWORD"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Ejecutar como root"; exit 1; }

# Valores por defecto de hostname / MAC (IP vacía = DHCP)
PROD_HOSTNAME="${PROD_HOSTNAME:-prod}"
DEV_HOSTNAME="${DEV_HOSTNAME:-dev}"
PBS_HOSTNAME="${PBS_HOSTNAME:-pbs}"
mac_for() { printf 'BC:24:11:A0:%02X:%02X' "$1" "$2"; }   # <vmid> <nic>  -> MAC fija y predecible
PROD_MAC="${PROD_MAC:-$(mac_for 100 0)}"
DEV_MAC="${DEV_MAC:-$(mac_for 110 0)}"
PBS_MAC="${PBS_MAC:-$(mac_for 120 0)}"
PROD_IP="${PROD_IP:-}"; DEV_IP="${DEV_IP:-}"; PBS_IP="${PBS_IP:-}"

SNIPPETS_DIR="/var/lib/vz/snippets"
IMG_DIR="/var/lib/vz/template/iso"
IMG_FILE="${IMG_DIR}/$(basename "$UBUNTU_IMG_URL")"
NFS_MNT="/mnt/pbs"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- wipe
stage_wipe() {
  log "Inventario actual del nodo $(hostname)"
  qm list 2>/dev/null || true
  pct list 2>/dev/null || true
  echo; pvesm list "$STORAGE" 2>/dev/null || true
  echo
  warn "Esto DESTRUYE todas las VMs y contenedores de este nodo, sus discos, los discos huérfanos"
  warn "de ${STORAGE}, los jobs de backup y los storages de tipo PBS. No hay vuelta atrás."
  read -r -p "Escribe el hostname del nodo ($(hostname)) para continuar: " ans
  [[ "$ans" == "$(hostname)" ]] || { echo "Cancelado."; exit 1; }
  read -r -p "Segunda confirmación, escribe BORRAR: " ans2
  [[ "$ans2" == "BORRAR" ]] || { echo "Cancelado."; exit 1; }

  log "Jobs de backup"
  for id in $(pvesh get /cluster/backup --output-format json | python3 -c 'import sys,json;[print(j["id"]) for j in json.load(sys.stdin)]'); do
    pvesh delete "/cluster/backup/${id}" && echo "  job ${id} borrado"
  done

  log "VMs"
  for id in $(qm list | awk 'NR>1{print $1}'); do
    qm stop "$id" --skiplock 1 2>/dev/null || true
    qm destroy "$id" --purge 1 --destroy-unreferenced-disks 1 --skiplock 1
    echo "  VM ${id} destruida"
  done

  log "Contenedores"
  for id in $(pct list | awk 'NR>1{print $1}'); do
    pct stop "$id" 2>/dev/null || true
    pct destroy "$id" --purge 1 --force 1
    echo "  CT ${id} destruido"
  done

  log "Discos huérfanos en ${STORAGE}"
  for vol in $(pvesm list "$STORAGE" | awk 'NR>1{print $1}'); do
    pvesm free "$vol" && echo "  ${vol} liberado"
  done

  log "Storages PBS y snippets antiguos"
  for st in $(pvesm status 2>/dev/null | awk '$2=="pbs"{print $1}'); do
    pvesm remove "$st" && echo "  storage ${st} eliminado"
  done
  rm -f "${SNIPPETS_DIR}"/*.yaml 2>/dev/null || true

  log "Nodo vacío. Siguiente: ./pve-a.sh host"
}

# ---------------------------------------------------------------- host
stage_host() {
  local old
  old="$(hostname)"

  log "Paquetes base y NFS"
  apt-get update -qq
  apt-get install -y -qq nfs-common wget python3 >/dev/null

  log "Snippets en storage local"
  pvesm set local --content backup,iso,vztmpl,snippets
  mkdir -p "$SNIPPETS_DIR"

  log "Hostname ${old} -> ${NODE_NAME}"
  if [[ "$old" != "$NODE_NAME" ]]; then
    hostnamectl set-hostname "$NODE_NAME"
    sed -i "/[[:space:]]${old}\(\.\|[[:space:]]\|$\)/d" /etc/hosts
    echo "${NODE_IP} ${NODE_NAME}.${LAN_DOMAIN} ${NODE_NAME}" >> /etc/hosts
    warn "El directorio /etc/pve/nodes/${old} se regenerará como ${NODE_NAME} tras el reinicio; el viejo se elimina en 'template'."
  fi

  log "Red: vmbr0 VLAN-aware con ${NODE_IP}/${LAN_CIDR}"
  local ports
  ports="$(awk '/^iface vmbr0/{f=1} f&&/bridge-ports/{print $2; exit}' /etc/network/interfaces)"
  [[ -n "$ports" ]] || { echo "No encuentro bridge-ports de vmbr0 en /etc/network/interfaces"; exit 1; }
  cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"
  cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

iface ${ports} inet manual

auto vmbr0
iface vmbr0 inet static
        address ${NODE_IP}/${LAN_CIDR}
        gateway ${LAN_GW}
        bridge-ports ${ports}
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        bridge-vids 2-4094

source /etc/network/interfaces.d/*
EOF
  printf 'search %s\nnameserver %s\n' "$LAN_DOMAIN" "$LAN_DNS" > /etc/resolv.conf

  log "Montaje NFS del NAS para el datastore de PBS"
  mkdir -p "$NFS_MNT"
  grep -q "${NFS_MNT}" /etc/fstab || echo "${NAS_IP}:/volume1/pbs ${NFS_MNT} nfs4 defaults,_netdev,noatime 0 0" >> /etc/fstab
  mount "$NFS_MNT" 2>/dev/null && echo "  NFS montado" || warn "No se pudo montar ${NAS_IP}:/volume1/pbs ahora; se intentará al arrancar"

  log "Listo. REINICIA el nodo (reboot) y conecta por SSH a ${NODE_IP}. Después: ./pve-a.sh all"
}

# ---------------------------------------------------------------- helpers
render_snippet() {  # render_snippet <src.yaml> <dst-name> <hostname>
  sed -e "s|__SSH_PUBKEY__|${SSH_PUBKEY}|g" \
      -e "s|__VM_USER__|${VM_USER}|g" \
      -e "s|__HOSTNAME__|$3|g" \
      -e "s|__LAN_DOMAIN__|${LAN_DOMAIN}|g" \
      "$1" > "${SNIPPETS_DIR}/$2"
}

ipcfg_lan() {  # ipcfg_lan <ip|vacío>  -> valor para --ipconfigN en LAN
  [[ -n "$1" ]] && echo "ip=$1/${LAN_CIDR},gw=${LAN_GW}" || echo "ip=dhcp"
}

vm_ips() {  # vm_ips <vmid> -> IPs v4 según el guest agent
  qm agent "$1" network-get-interfaces 2>/dev/null | python3 -c '
import sys,json
for i in json.load(sys.stdin):
    if i["name"]=="lo": continue
    ips=[a["ip-address"] for a in i.get("ip-addresses",[]) if a["ip-address-type"]=="ipv4"]
    print(f"    {i[\"name\"]:6} {i.get(\"hardware-address\",\"\"):18} {\" \".join(ips) or \"(sin IP)\"}")' 2>/dev/null || echo "    (agent no disponible aún)"
}

wait_for_agent() {  # wait_for_agent <vmid> <segundos>
  local i=0
  until qm agent "$1" ping >/dev/null 2>&1; do
    sleep 5; i=$((i+5)); [[ $i -lt $2 ]] || { warn "VM $1: guest agent no responde tras $2 s (cloud-init puede seguir trabajando)"; return 0; }
  done
  echo "  VM $1: guest agent OK"
}

# ---------------------------------------------------------------- template
stage_template() {
  [[ "$(hostname)" == "$NODE_NAME" ]] || { echo "El hostname aún es $(hostname); ejecuta 'host' y reinicia"; exit 1; }
  for d in /etc/pve/nodes/*; do
    [[ "$(basename "$d")" == "$NODE_NAME" ]] || { rm -rf "$d"; echo "  eliminado $(basename "$d") de /etc/pve/nodes"; }
  done
  pvecm updatecerts -f >/dev/null 2>&1 || true

  log "Imagen cloud Ubuntu 26.04"
  mkdir -p "$IMG_DIR"
  if [[ ! -f "$IMG_FILE" ]]; then
    wget -q --show-progress -O "$IMG_FILE" "$UBUNTU_IMG_URL"
  fi
  ( cd "$IMG_DIR" && wget -qO SHA256SUMS.ubuntu "$UBUNTU_SUMS_URL" && grep "$(basename "$IMG_FILE")" SHA256SUMS.ubuntu | sha256sum -c - )

  log "Plantilla 9000 ubuntu2604-cloudinit"
  qm destroy 9000 --purge 1 2>/dev/null || true
  qm create 9000 --name ubuntu2604-cloudinit --ostype l26 \
    --cpu host --cores 2 --memory 2048 \
    --scsihw virtio-scsi-single \
    --net0 virtio,bridge=vmbr0 \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --serial0 socket --vga serial0 \
    --tags template
  qm set 9000 --scsi0 "${STORAGE}:0,import-from=${IMG_FILE},discard=on,ssd=1,iothread=1"
  qm set 9000 --ide2 "${STORAGE}:cloudinit" --boot order=scsi0
  qm set 9000 --nameserver "$LAN_DNS" --searchdomain "$LAN_DOMAIN"
  qm template 9000
  echo "  plantilla lista"
}

# ---------------------------------------------------------------- prod
stage_prod() {
  log "VM 100 ${PROD_HOSTNAME}"
  qm destroy 100 --purge 1 2>/dev/null || true
  render_snippet "${HERE}/snippets/prod-user.yaml" prod-user.yaml "$PROD_HOSTNAME"
  qm clone 9000 100 --name "$PROD_HOSTNAME" --full 1
  qm set 100 --cores 2 --memory 8192 --balloon 0 --onboot 1 --startup order=1 --tags prod
  qm set 100 --net0 "virtio=${PROD_MAC},bridge=vmbr0"
  qm set 100 --ipconfig0 "$(ipcfg_lan "$PROD_IP")"
  qm set 100 --cicustom "user=local:snippets/prod-user.yaml"
  qm resize 100 scsi0 250G
  qm start 100
  wait_for_agent 100 300
  vm_ips 100
}

# ---------------------------------------------------------------- dev
stage_dev() {
  log "VM 110 ${DEV_HOSTNAME}"
  qm destroy 110 --purge 1 2>/dev/null || true
  render_snippet "${HERE}/snippets/dev-user.yaml" dev-user.yaml "$DEV_HOSTNAME"
  qm clone 9000 110 --name "$DEV_HOSTNAME" --full 1
  qm set 110 --cores 2 --memory 12288 --balloon 0 --onboot 1 --startup order=2 --tags dev
  qm set 110 --net0 "virtio=${DEV_MAC},bridge=vmbr0"
  qm set 110 --ipconfig0 "$(ipcfg_lan "$DEV_IP")"
  qm set 110 --cicustom "user=local:snippets/dev-user.yaml"
  qm resize 110 scsi0 200G
  qm start 110
  wait_for_agent 110 600
  vm_ips 110
}

# ---------------------------------------------------------------- pbs
stage_pbs() {
  log "LXC 120 pbs (Debian 13 + Proxmox Backup Server)"
  mountpoint -q "$NFS_MNT" || mount "$NFS_MNT" || { echo "NFS ${NAS_IP}:/volume1/pbs no montado en ${NFS_MNT}"; exit 1; }
  chmod 1777 "$NFS_MNT" 2>/dev/null || true

  pct destroy 120 --purge 1 --force 1 2>/dev/null || true
  pveam update >/dev/null
  local tmpl
  tmpl="$(pveam available --section system | awk '/debian-13-standard/{print $2}' | sort -V | tail -1)"
  [[ -n "$tmpl" ]] || { echo "No encuentro plantilla debian-13-standard"; exit 1; }
  [[ -f "/var/lib/vz/template/cache/${tmpl}" ]] || pveam download local "$tmpl"

  local pbs_net
  if [[ -n "$PBS_IP" ]]; then pbs_net="ip=${PBS_IP}/${LAN_CIDR},gw=${LAN_GW}"; else pbs_net="ip=dhcp"; fi
  pct create 120 "local:vztmpl/${tmpl}" \
    --hostname "$PBS_HOSTNAME" --unprivileged 1 --features nesting=1 \
    --cores 1 --memory 2048 --swap 512 \
    --rootfs "${STORAGE}:8" \
    --net0 "name=eth0,bridge=vmbr0,hwaddr=${PBS_MAC},${pbs_net}" \
    --nameserver "$LAN_DNS" --searchdomain "$LAN_DOMAIN" \
    --password "$PBS_ROOT_PASSWORD" \
    --onboot 1 --startup order=3 --tags pbs
  pct set 120 --mp0 "${NFS_MNT},mp=/mnt/datastore/nas"
  pct start 120
  local pbs_addr="$PBS_IP" i=0
  until [[ -n "$pbs_addr" ]]; do
    sleep 3; i=$((i+3))
    pbs_addr="$(pct exec 120 -- hostname -I 2>/dev/null | awk '{print $1}')"
    [[ $i -lt 90 ]] || { echo "El LXC 120 no ha obtenido IP por DHCP en 90 s"; exit 1; }
  done
  echo "  PBS en ${pbs_addr} (MAC ${PBS_MAC})"
  sleep 5

  log "Instalando PBS dentro del LXC"
  pct exec 120 -- bash -ceu '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq wget gnupg >/dev/null
    wget -qO /usr/share/keyrings/proxmox-archive-keyring.gpg https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
    echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45 /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum -c - >/dev/null
    cat > /etc/apt/sources.list.d/pbs.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    apt-get update -qq && apt-get install -y -qq proxmox-backup-server >/dev/null
    proxmox-backup-manager datastore create nas /mnt/datastore/nas --gc-schedule "sun 04:00"
    proxmox-backup-manager prune-job create prune-nas --store nas --schedule "daily 03:30" \
      --keep-daily 7 --keep-weekly 4 --keep-monthly 3 2>/dev/null || true
    proxmox-backup-manager verify-job create verify-nas --store nas --schedule "sat 05:00" --ignore-verified true --outdated-after 30 2>/dev/null || true
  '

  log "Storage PBS en Proxmox VE y job de backup"
  local fp
  fp="$(pct exec 120 -- proxmox-backup-manager cert info | awk '/Fingerprint/{print $NF}')"
  pvesm remove nas-pbs 2>/dev/null || true
  pvesm add pbs nas-pbs --server "$pbs_addr" --datastore nas \
    --username root@pam --password "$PBS_ROOT_PASSWORD" --fingerprint "$fp" --content backup
  pvesh create /cluster/backup --id daily-prod-dev --storage nas-pbs --vmid 100,110 \
    --schedule "03:00" --mode snapshot --enabled 1 --notes-template '{{guestname}}' \
    --prune-backups keep-daily=7,keep-weekly=4,keep-monthly=3
  echo "  PBS web: https://${pbs_addr}:8007  (root@pam)"
  [[ -n "$PBS_IP" ]] || warn "PBS va por DHCP: el storage 'nas-pbs' apunta a ${pbs_addr}. Reserva esa IP para ${PBS_MAC} en el MikroTik o los backups fallarán si cambia."
}

print_macs() {
  cat <<EOF

  MACs de las máquinas (para las reservas DHCP en el MikroTik):
    100 ${PROD_HOSTNAME}  LAN  ${PROD_MAC}
    110 ${DEV_HOSTNAME}   LAN  ${DEV_MAC}
    120 ${PBS_HOSTNAME}   LAN  ${PBS_MAC}
EOF
}

# ---------------------------------------------------------------- main
case "${1:-}" in
  wipe)     stage_wipe ;;
  host)     stage_host ;;
  template) stage_template ;;
  prod)     stage_prod ;;
  dev)      stage_dev ;;
  pbs)      stage_pbs ;;
  macs)     print_macs ;;
  all)      stage_template; stage_prod; stage_dev; stage_pbs
            log "pve-a completo"; qm list; pct list; print_macs ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
