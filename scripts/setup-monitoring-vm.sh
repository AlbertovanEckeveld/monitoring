#!/usr/bin/env bash
# Zet de MONITORING-VM in één keer volledig op. Deze VM is ook de LOAD-GENERATOR.
# Veilig om opnieuw te draaien (idempotent).
#
#   sudo ./scripts/setup-monitoring-vm.sh
#
# Opties:
#   --phase ceph|seaweedfs  testfase (standaard: huidige fase, anders ceph)
#   --ceph-branch NAAM      branch voor de Ceph-dashboards (standaard: squid)
#   --hostname NAAM         naam waarmee nodes deze VM bereiken (standaard: hostname -f)
#   --skip-dashboards       officiële dashboards niet (opnieuw) ophalen
#
# Wat het doet:
#   1. installeert docker (+ compose-plugin), chrony, curl, jq, openssl en fio
#   2. maakt .env met een willekeurig Grafana-wachtwoord (als die nog niet bestaat)
#   3. zet deze VM als load-generator in prometheus/targets/node.yml (system=loadgen)
#   4. haalt de officiële Ceph/SeaweedFS-dashboards op
#   5. zet de testfase (scripts/set-phase.sh) en valideert de Prometheus-config
#   6. start de stack en wacht tot alles gezond is
#   7. maakt een Grafana-service-account 'benchmark' en schrijft bench.env
#      (GRAFANA_URL, GRAFANA_TOKEN, PUSHGATEWAY_URL), dat run-bench.sh automatisch inleest
#   8. opent de poorten in firewalld/ufw (als die actief is)
set -euo pipefail

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PHASE="" CEPH_BRANCH="squid" VM_HOST="" SKIP_DASH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)           PHASE="$2"; shift 2 ;;
    --ceph-branch)     CEPH_BRANCH="$2"; shift 2 ;;
    --hostname)        VM_HOST="$2"; shift 2 ;;
    --skip-dashboards) SKIP_DASH=1; shift ;;
    -h|--help)         sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "Onbekende optie: $1" >&2; exit 1 ;;
  esac
done
VM_HOST="${VM_HOST:-$(hostname -f 2>/dev/null || hostname)}"

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWAARSCHUWING: %s\033[0m\n' "$*" >&2; }

# ---------------------------------------------------------------- pakketten
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

enable_chrony() {
  systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd
  chronyc makestep >/dev/null 2>&1 || true
}

open_ports() {
  if systemctl is-active -q firewalld 2>/dev/null; then
    for p in "$@"; do firewall-cmd -q --permanent --add-port="$p/tcp"; done
    firewall-cmd -q --reload; echo "firewalld: $* open"
  elif command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    for p in "$@"; do ufw allow "$p/tcp" >/dev/null; done; echo "ufw: $* open"
  fi
}

wait_for() {  # naam url seconden
  local i
  for ((i = 0; i < $3; i += 2)); do
    curl -fsS -o /dev/null "$2" 2>/dev/null && { echo "  $1: OK"; return 0; }
    sleep 2
  done
  warn "$1 reageert niet op $2"; return 1
}

log "1/8 Pakketten, docker en chrony"
install_pkgs curl jq chrony openssl ca-certificates fio   # fio: deze VM is ook de load-generator
install_docker
enable_chrony
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] && usermod -aG docker "$SUDO_USER"

log "2/8 .env"
if [[ ! -f .env ]]; then
  cp .env.example .env
  PW="$(openssl rand -base64 18 | tr -d '/+=')"
  sed -i "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$PW/" .env
  chmod 600 .env
  echo "Nieuw Grafana-admin-wachtwoord aangemaakt (staat in .env)"
else
  echo ".env bestaat al, niet aangepast"
fi
set -a; . ./.env; set +a
: "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD is leeg in .env}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"

log "3/8 Deze VM als load-generator in targets/node.yml"
SHORT_HOST="$(hostname -s)"
sed -i "s/^    instance: .*/    instance: $SHORT_HOST/" prometheus/targets/node.yml
echo "node.yml: host.docker.internal:9100 -> system=loadgen, instance=$SHORT_HOST"

log "4/8 Dashboards"
if [[ $SKIP_DASH -eq 0 ]]; then
  ./scripts/fetch-dashboards.sh "$CEPH_BRANCH" || warn "dashboards ophalen mislukt (geen internet?); later opnieuw: ./scripts/fetch-dashboards.sh"
else
  echo "overgeslagen"
fi

log "5/8 Testfase en Prometheus-config"
if [[ -z "$PHASE" ]]; then
  PHASE="$(sed -n 's/^# Huidige fase: //p' prometheus/targets/storage-nodes.yml 2>/dev/null || true)"
  PHASE="${PHASE:-ceph}"
fi
NO_ANNOTATION=1 ./scripts/set-phase.sh "$PHASE"

# Containers draaien als non-root (Prometheus: nobody, Loki: 10001): alles leesbaar maken
chmod -R a+rX prometheus grafana loki

PROM_IMAGE="$(awk '/image: prom\/prometheus:/ {print $2; exit}' docker-compose.yml)"
docker run --rm -v "$ROOT/prometheus:/etc/prometheus:ro" --entrypoint promtool "$PROM_IMAGE" \
  check config /etc/prometheus/prometheus.yml

# Hostnamen moeten vanaf deze VM op te lossen zijn
for h in $(grep -rhoE "'[A-Za-z0-9._-]+:[0-9]+'" prometheus/targets/*.yml | tr -d "'" | cut -d: -f1 | sort -u | grep -v '^host.docker.internal$'); do
  getent hosts "$h" >/dev/null || warn "hostnaam '$h' niet op te lossen (DNS of /etc/hosts aanvullen)"
done

log "6/8 Stack starten"
docker compose pull -q
docker compose up -d
wait_for Prometheus  http://localhost:9090/-/ready     60  || true
wait_for Pushgateway http://localhost:9091/-/ready     60  || true
wait_for Grafana     http://localhost:3000/api/health  90  || true
wait_for Loki        http://localhost:3100/ready       120 || true

log "7/8 Grafana-token voor benchmarks (bench.env)"
GURL=http://localhost:3000
g() { curl -fsS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' "$@"; }

token_ok() {
  [[ -f bench.env ]] || return 1
  local t; t="$(sed -n 's/^GRAFANA_TOKEN=//p' bench.env)"
  [[ -n "$t" ]] && curl -fsS -o /dev/null -H "Authorization: Bearer $t" "$GURL/api/search?limit=1"
}

if token_ok; then
  echo "bench.env bestaat al en het token werkt"
else
  SA_ID="$(g "$GURL/api/serviceaccounts/search?query=benchmark" \
    | jq -r '.serviceAccounts[] | select(.name=="benchmark") | .id' | head -n1)"
  if [[ -z "$SA_ID" ]]; then
    SA_ID="$(g -X POST "$GURL/api/serviceaccounts" -d '{"name":"benchmark","role":"Editor"}' | jq -r .id)"
  fi
  TOKEN="$(g -X POST "$GURL/api/serviceaccounts/$SA_ID/tokens" \
    -d "{\"name\":\"bench-$(date +%Y%m%d%H%M%S)\"}" | jq -r .key)"
  umask 077
  cat > bench.env <<EOF
# Gegenereerd door setup-monitoring-vm.sh (deze VM is ook de load-generator).
# run-bench.sh en set-phase.sh lezen dit bestand automatisch in.
GRAFANA_URL=http://localhost:3000
GRAFANA_TOKEN=$TOKEN
PUSHGATEWAY_URL=http://localhost:9091
EOF
  umask 022
  echo "bench.env geschreven"
fi

log "8/8 Firewall"
# 9100: node_exporter van deze VM, die Prometheus via de docker-bridge scrapet
open_ports 3000 9090 9091 3100 9100

# Bestanden terug naar de gebruiker die sudo deed, zodat je ze zonder root kunt aanpassen
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  chown -R "$SUDO_USER": prometheus/targets grafana/dashboards results .env bench.env 2>/dev/null || true
fi

log "Klaar"
cat <<EOF
  Grafana:      http://$VM_HOST:3000   (gebruiker: $GRAFANA_ADMIN_USER, wachtwoord in .env)
  Prometheus:   http://$VM_HOST:9090/targets
  Loki (push):  http://$VM_HOST:3100/loki/api/v1/push
  Fase:         $PHASE

Volgende stap: de 4 storage-nodes opzetten (vanaf deze VM):
  for h in sue-poc-storage01 sue-poc-storage02 sue-poc-storage03 sue-poc-storage04; do
    scp -r $ROOT/nodes "\$h":~/ && ssh -t "\$h" "sudo ~/nodes/setup-node.sh ceph $VM_HOST"
  done

Benchmarks draai je op deze VM: ./scripts/run-bench.sh ceph <testnaam> -- <commando>
(warp voor S3-tests installeer je zelf: https://github.com/minio/warp/releases)
EOF
