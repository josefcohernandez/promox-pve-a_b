#!/usr/bin/env bash
# Preparación del nodo pve-b (Proxmox VE 9). Ejecutar como root EN EL NODO.
# Aquí NO se crea ninguna VM: todo lo que vive en pve-b lo crea OpenTofu desde dev.
#
#   ./pve-b.sh wipe   -> borra TODAS las VMs/LXC y discos huérfanos (doble confirmación)
#   ./pve-b.sh host   -> hostname, red (vmbr0 VLAN-aware, IP fija), contenido snippets+import en 'local'  (REINICIAR después)
#   ./pve-b.sh tofu   -> usuario/rol/token de API para OpenTofu + usuario Linux 'terraform' con SSH y sudo restringido
#
# Orden la primera vez:  wipe -> host -> reboot -> tofu
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HERE}/pve-b.env"
[[ -f "$ENV_FILE" ]] || { echo "Falta ${ENV_FILE} (copia pve-b.env.example)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
for v in NODE_NAME NODE_IP LAN_GW STORAGE; do
  [[ -n "${!v:-}" ]] || { echo "Variable $v vacía en pve-b.env"; exit 1; }
done
[[ $EUID -eq 0 ]] || { echo "Ejecutar como root"; exit 1; }

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- wipe
stage_wipe() {
  log "Inventario actual del nodo $(hostname)"
  qm list 2>/dev/null || true
  pct list 2>/dev/null || true
  echo; pvesm list "$STORAGE" 2>/dev/null || true
  echo
  warn "Esto DESTRUYE todas las VMs y contenedores de este nodo, sus discos y los discos huérfanos de ${STORAGE}."
  read -r -p "Escribe el hostname del nodo ($(hostname)) para continuar: " ans
  [[ "$ans" == "$(hostname)" ]] || { echo "Cancelado."; exit 1; }
  read -r -p "Segunda confirmación, escribe BORRAR: " ans2
  [[ "$ans2" == "BORRAR" ]] || { echo "Cancelado."; exit 1; }

  for id in $(qm list | awk 'NR>1{print $1}'); do
    qm stop "$id" --skiplock 1 2>/dev/null || true
    qm destroy "$id" --purge 1 --destroy-unreferenced-disks 1 --skiplock 1
    echo "  VM ${id} destruida"
  done
  for id in $(pct list | awk 'NR>1{print $1}'); do
    pct stop "$id" 2>/dev/null || true
    pct destroy "$id" --purge 1 --force 1
    echo "  CT ${id} destruido"
  done
  for vol in $(pvesm list "$STORAGE" | awk 'NR>1{print $1}'); do
    pvesm free "$vol" && echo "  ${vol} liberado"
  done
  rm -f /var/lib/vz/snippets/*.yaml 2>/dev/null || true
  log "Nodo vacío. Siguiente: ./pve-b.sh host"
}

# ---------------------------------------------------------------- host
stage_host() {
  local old
  old="$(hostname)"

  log "Paquetes base"
  apt-get update -qq && apt-get install -y -qq wget python3 sudo >/dev/null

  log "Contenido de 'local': snippets (cloud-init) e import (imágenes cloud que descarga OpenTofu)"
  pvesm set local --content backup,iso,vztmpl,snippets,import
  mkdir -p /var/lib/vz/snippets /var/lib/vz/import

  log "Hostname ${old} -> ${NODE_NAME}"
  if [[ "$old" != "$NODE_NAME" ]]; then
    hostnamectl set-hostname "$NODE_NAME"
    sed -i "/[[:space:]]${old}\(\.\|[[:space:]]\|$\)/d" /etc/hosts
    echo "${NODE_IP} ${NODE_NAME}.${LAN_DOMAIN} ${NODE_NAME}" >> /etc/hosts
  fi

  log "Red: vmbr0 VLAN-aware con ${NODE_IP}/${LAN_CIDR}"
  local ports
  ports="$(awk '/^iface vmbr0/{f=1} f&&/bridge-ports/{print $2; exit}' /etc/network/interfaces)"
  [[ -n "$ports" ]] || { echo "No encuentro bridge-ports de vmbr0"; exit 1; }
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

  log "Listo. REINICIA el nodo (reboot), conecta a ${NODE_IP} y ejecuta: ./pve-b.sh tofu"
}

# ---------------------------------------------------------------- tofu
stage_tofu() {
  [[ "$(hostname)" == "$NODE_NAME" ]] || { echo "El hostname aún es $(hostname); ejecuta 'host' y reinicia"; exit 1; }
  [[ -n "${TOFU_SSH_PUBKEY:-}" && "$TOFU_SSH_PUBKEY" != *AAAA...* ]] || { echo "Rellena TOFU_SSH_PUBKEY en pve-b.env (clave generada en dev)"; exit 1; }
  for d in /etc/pve/nodes/*; do
    [[ "$(basename "$d")" == "$NODE_NAME" ]] || { rm -rf "$d"; echo "  eliminado $(basename "$d") de /etc/pve/nodes"; }
  done
  pvecm updatecerts -f >/dev/null 2>&1 || true

  log "Rol y usuario de API terraform@pve (privilegios recomendados por el provider bpg)"
  local privs="Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
Group.Allocate Mapping.Audit Mapping.Modify Mapping.Use Permissions.Modify Pool.Allocate Pool.Audit \
Realm.Allocate Realm.AllocateUser SDN.Allocate SDN.Audit SDN.Use Sys.AccessNetwork Sys.Audit Sys.Console \
Sys.Incoming Sys.Modify Sys.PowerMgmt Sys.Syslog User.Modify VM.Allocate VM.Audit VM.Backup VM.Clone \
VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory \
VM.Config.Network VM.Config.Options VM.Console VM.GuestAgent.Audit VM.GuestAgent.FileRead \
VM.GuestAgent.FileSystemMgmt VM.GuestAgent.FileWrite VM.GuestAgent.Unrestricted VM.Migrate VM.Monitor \
VM.PowerMgmt VM.Replicate VM.Snapshot VM.Snapshot.Rollback"
  pveum role delete Terraform 2>/dev/null || true
  pveum role add Terraform -privs "${privs}"
  pveum user add terraform@pve --comment "OpenTofu desde dev" 2>/dev/null || true
  pveum aclmod / -user terraform@pve -role Terraform
  pveum user token remove terraform@pve tofu 2>/dev/null || true
  local token
  token="$(pveum user token add terraform@pve tofu --privsep 0 --output-format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')"

  log "Usuario Linux 'terraform' para SSH (subida de snippets) con sudo restringido"
  id terraform >/dev/null 2>&1 || useradd -m -s /bin/bash terraform
  install -d -m 700 -o terraform -g terraform /home/terraform/.ssh
  echo "$TOFU_SSH_PUBKEY" > /home/terraform/.ssh/authorized_keys
  chmod 600 /home/terraform/.ssh/authorized_keys; chown terraform:terraform /home/terraform/.ssh/authorized_keys
  cat > /etc/sudoers.d/terraform <<'EOF'
terraform ALL=(root) NOPASSWD: /usr/sbin/pvesm apiinfo
terraform ALL=(root) NOPASSWD: /usr/bin/tee /var/lib/vz/snippets/[a-zA-Z0-9_][a-zA-Z0-9_.-]*
EOF
  chmod 440 /etc/sudoers.d/terraform
  visudo -cf /etc/sudoers.d/terraform >/dev/null

  cat <<EOF

================================================================================
  Guarda esto en dev (por ejemplo en ~/.config/tofu/pve-b.env, NO en Git):

  export PROXMOX_VE_ENDPOINT="https://${NODE_IP}:8006/"
  export PROXMOX_VE_API_TOKEN="terraform@pve!tofu=${token}"
  export PROXMOX_VE_SSH_USERNAME="terraform"

  El token solo se muestra esta vez. Si lo pierdes: ./pve-b.sh tofu (lo regenera).
  Prueba desde dev:  ssh terraform@${NODE_IP} sudo pvesm apiinfo
================================================================================
EOF
}

case "${1:-}" in
  wipe) stage_wipe ;;
  host) stage_host ;;
  tofu) stage_tofu ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
