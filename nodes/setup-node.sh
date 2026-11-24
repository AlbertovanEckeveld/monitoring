#!/usr/bin/env bash
# Zet een STORAGE-NODE (sue-poc-storage01-04) op. Idempotent.
# (De monitoring-VM is ook de load-generator; die zet je op met scripts/setup-monitoring-vm.sh.)
#
#   sudo ./setup-node.sh <ceph|seaweedfs> <monitoring-vm-host>
#
# Voorbeeld:
#   sudo ./setup-node.sh ceph monitoring-vm        # vóór de snapshot
#
# Wat het doet:
#   1. installeert docker (+ compose-plugin), chrony en curl
#   2. zet de klok gelijk (chrony)
#   3. schrijft .env (SYSTEM, LOKI_URL)
#   4. opent poorten in firewalld/ufw: 9100 (node_exporter) en 9324-9327 (SeaweedFS-metrics)
#   5. controleert dat poort 9100 vrij is (geen node-exporter van cephadm)
#   6. start node_exporter + Alloy via ./set-phase.sh
#
# Draai dit VÓÓR de snapshot. Na de snapshot-revert alleen: ./set-phase.sh seaweedfs
set -euo pipefail

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
cd "$(dirname "$0")"

ROLE="${1:-}" MON="${2:-}"
if [[ ! "$ROLE" =~ ^(ceph|seaweedfs)$ || -z "$MON" ]]; then
  sed -n '2,19p' "$0"; exit 1
fi

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWAARSCHUWING: %s\033[0m\n' "$*" >&2; }

install_pkgs() {
  if command -v apt-get >/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null; then
    dnf install -y -q "$@"
  else
    echo "Geen apt-get of dnf gevonden; installeer handmatig: $*" >&2; exit 1
  fi
}

install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    echo "docker al aanwezig: $(docker --version)"; return
  fi
  . /etc/os-release
  case "$ID" in
    ubuntu|debian|fedora|centos)
      curl -fsSL https://get.docker.com | sh ;;
    rhel|rocky|almalinux|ol)
      local repo=centos; [[ "$ID" == rhel ]] && repo=rhel
      dnf install -y -q dnf-plugins-core
      dnf config-manager --add-repo "https://download.docker.com/linux/$repo/docker-ce.repo"
      # --allowerasing: docker-ce botst met podman/runc; cephadm werkt ook met docker
      dnf install -y -q --allowerasing docker-ce docker-ce-cli containerd.io docker-compose-plugin ;;
    *) echo "Onbekende distributie '$ID'; installeer docker + compose-plugin handmatig" >&2; exit 1 ;;
  esac
  systemctl enable --now docker
}

open_ports() {
  if systemctl is-active -q firewalld 2>/dev/null; then
    for p in "$@"; do firewall-cmd -q --permanent --add-port="$p/tcp"; done
    firewall-cmd -q --reload; echo "firewalld: $* open"
  elif command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    for p in "$@"; do ufw allow "${p/-/:}/tcp" >/dev/null; done; echo "ufw: $* open"
  else
    echo "geen actieve firewall gevonden"
  fi
}

log "1/6 Pakketten en docker"
install_pkgs curl chrony ca-certificates
install_docker

log "2/6 Tijdsynchronisatie"
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd
chronyc makestep >/dev/null 2>&1 || true
chronyc tracking 2>/dev/null | grep -E 'Reference ID|System time' || true

log "3/6 .env"
[[ -f .env ]] || cp .env.example .env
LOKI_URL="http://$MON:3100/loki/api/v1/push"
if grep -q '^LOKI_URL=' .env; then
  sed -i "s|^LOKI_URL=.*|LOKI_URL=$LOKI_URL|" .env
else
  echo "LOKI_URL=$LOKI_URL" >> .env
fi
echo "LOKI_URL=$LOKI_URL"

log "4/6 Firewall"
open_ports 9100 9324-9327

log "5/6 Controles"
curl -fsS -o /dev/null --max-time 5 "http://$MON:3100/ready" \
  && echo "Loki op $MON bereikbaar" \
  || warn "Loki op $MON:3100 niet bereikbaar; logs komen pas binnen als dat werkt"

if ss -Hltn 'sport = :9100' | grep -q . \
   && ! docker ps --format '{{.Names}}' | grep -q 'storage-agents-node-exporter'; then
  warn "poort 9100 is al bezet door iets anders (cephadm node-exporter?)."
  warn "Op het Ceph-cluster: 'ceph orch rm node-exporter', of bootstrap met --skip-monitoring-stack."
  ss -ltnp 'sport = :9100' >&2 || true
  exit 1
fi

log "6/6 Agents starten"
./set-phase.sh "$ROLE"

sleep 3
curl -fsS -o /dev/null http://localhost:9100/metrics \
  && echo "node_exporter: OK" || warn "node_exporter reageert niet op :9100"
docker compose ps

cat <<EOF

Klaar. Controleer op http://$MON:9090/targets dat $(hostname) UP is.
Als alle 4 nodes UP zijn, kun je de snapshot maken.
EOF
