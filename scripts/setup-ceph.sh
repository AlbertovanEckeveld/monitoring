#!/usr/bin/env bash
# Rol Ceph (cephadm) in één keer uit op sue-poc-storage01-04. Veilig om opnieuw te draaien.
# Draai dit vanaf je laptop of de monitoring-VM: alles gaat via SSH (met sudo) naar de storage-nodes.
#
#   ./scripts/setup-ceph.sh [opties]
#
# Opties:
#   --hosts BESTAND   regels "naam: ip" (standaard: hosts.md); alleen sue-poc-storage* wordt gebruikt,
#                     de eerste is de bootstrap-node
#   --user NAAM       SSH-gebruiker met sudo (standaard: $SSH_USER, anders ubuntu)
#   -i BESTAND        SSH-sleutel
#   --release NAAM    Ceph-release (standaard: squid)
#   --no-rgw          geen RGW (S3) uitrollen
#
# Voorwaarden:
#   - setup-node.sh is al op de nodes gedraaid (docker, chrony, node_exporter op 9100)
#   - elke node heeft minstens één lege schijf (extra EBS-volume) voor de OSD's
#   - de AWS security group laat al het verkeer tussen de storage-nodes toe, en vanaf de
#     monitoring-VM 9283 (mgr), 9926 (ceph-exporter) en 8080 (RGW)
#
# Wat het doet:
#   1. per node: private IP bepalen, hostname gelijk aan hosts.md, /etc/hosts met de private IP's,
#      python3/lvm2 installeren, root-login met sleutel toestaan (nodig voor cephadm), poorten openen
#   2. cephadm installeren en bootstrappen op de eerste node met --skip-monitoring-stack
#      (dan blijft poort 9100 vrij voor onze eigen node_exporter)
#   3. de cephadm-SSH-sleutel op de andere nodes zetten en ze aan het cluster toevoegen
#   4. 3 mons, mgr op 01+02 (zie prometheus/targets/ceph-mgr.yml), OSD's op alle vrije schijven,
#      mgr/prometheus (scrape-interval 5s), ceph-exporter en RGW op poort 8080
#   5. wacht op de OSD's en RGW en schrijft ceph-s3.env (endpoint + S3-sleutels voor warp)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOSTS_FILE="$ROOT/hosts.md" SSH_USER="${SSH_USER:-ubuntu}" SSH_KEY="" RELEASE="squid" RGW=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hosts)   HOSTS_FILE="$2"; shift 2 ;;
    --user)    SSH_USER="$2"; shift 2 ;;
    -i)        SSH_KEY="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    --no-rgw)  RGW=0; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "Onbekende optie: $1" >&2; exit 1 ;;
  esac
done

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWAARSCHUWING: %s\033[0m\n' "$*" >&2; }

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

# rsh <ip> <script> [args...]: voer een bash-script als root uit op een node.
# De argumenten worden met %q gequote, want ssh plakt ze tot één commandoregel.
rsh() {
  local ip="$1" script="$2"; shift 2
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "sudo bash -s -- $(printf '%q ' "$@")" <<<"$script"
}

# ------------------------------------------------------------------ hosts lezen
[[ -f "$HOSTS_FILE" ]] || { echo "Niet gevonden: $HOSTS_FILE" >&2; exit 1; }
NAMES=() PUB=()
while IFS=': ' read -r name ip || [[ -n "$name" ]]; do
  [[ "$name" == sue-poc-storage* && -n "$ip" ]] || continue
  NAMES+=("$name"); PUB+=("$ip")
done < <(tr -d '\r' < "$HOSTS_FILE" | sed 's/^[-* ]*//; s/`//g')
(( ${#NAMES[@]} >= 3 )) || { echo "Minstens 3 storage-nodes nodig in $HOSTS_FILE, gevonden: ${#NAMES[@]}" >&2; exit 1; }
BOOT_PUB="${PUB[0]}"

# ------------------------------------------------------------------ 1. nodes voorbereiden
log "1/5 Private IP's bepalen"
PRIV=()
for i in "${!NAMES[@]}"; do
  ip=$(rsh "${PUB[$i]}" 'ip -4 -o route get 1.1.1.1 | sed -n "s/.* src \([0-9.]*\).*/\1/p"')
  [[ -n "$ip" ]] || { echo "Geen private IP gevonden op ${NAMES[$i]} (${PUB[$i]})" >&2; exit 1; }
  PRIV+=("$ip")
  printf '  %-20s publiek %-16s privé %s\n' "${NAMES[$i]}" "${PUB[$i]}" "$ip"
done

HOSTS_LINES=()
for i in "${!NAMES[@]}"; do HOSTS_LINES+=("${PRIV[$i]} ${NAMES[$i]}"); done

PREP_SCRIPT=$(cat <<'EOS'
set -euo pipefail
NAME="$1"; shift

install_pkgs() {
  if command -v apt-get >/dev/null; then
    apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  else
    dnf install -y -q "$@"
  fi
}

# cephadm eist dat de hostname gelijk is aan de naam waarmee de host wordt toegevoegd
if [[ "$(hostname -s)" != "$NAME" ]]; then
  hostnamectl set-hostname "$NAME"
  [[ -d /etc/cloud/cloud.cfg.d ]] && echo 'preserve_hostname: true' > /etc/cloud/cloud.cfg.d/99-ceph-poc-hostname.cfg
  echo "hostname -> $NAME"
fi

# /etc/hosts: de storage-nodes op hun private IP
sed -i '/^# BEGIN ceph-poc/,/^# END ceph-poc/d' /etc/hosts
{ echo '# BEGIN ceph-poc'; printf '%s\n' "$@"; echo '# END ceph-poc'; } >> /etc/hosts

missing=()
command -v python3  >/dev/null || missing+=(python3)
command -v lvcreate >/dev/null || missing+=(lvm2)
command -v chronyc  >/dev/null || missing+=(chrony)
(( ${#missing[@]} )) && install_pkgs "${missing[@]}"
if ! command -v docker >/dev/null && ! command -v podman >/dev/null; then install_pkgs podman; fi

# cephadm logt als root in met een sleutel
if sshd -T 2>/dev/null | grep -qi '^permitrootlogin no'; then
  echo 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/00-cephadm.conf
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  echo "root-login met sleutel aangezet"
fi

PORTS=(3300 6789 6800-7300 8080 8443 8765 9283 9926)
if systemctl is-active -q firewalld 2>/dev/null; then
  for p in "${PORTS[@]}"; do firewall-cmd -q --permanent --add-port="$p/tcp"; done
  firewall-cmd -q --reload; echo "firewalld: Ceph-poorten open"
elif command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  for p in "${PORTS[@]}"; do ufw allow "${p/-/:}/tcp" >/dev/null; done; echo "ufw: Ceph-poorten open"
fi

if ss -Hltn 'sport = :9100' | grep -q . && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q node-exporter; then
  echo "WAARSCHUWING: poort 9100 is bezet door iets anders dan onze node_exporter" >&2
fi
echo "$NAME: klaar"
EOS
)

log "2/5 Nodes voorbereiden"
for i in "${!NAMES[@]}"; do
  rsh "${PUB[$i]}" "$PREP_SCRIPT" "${NAMES[$i]}" "${HOSTS_LINES[@]}"
done

# ------------------------------------------------------------------ 2. bootstrap
BOOT_SCRIPT=$(cat <<'EOS'
set -euo pipefail
RELEASE="$1" MON_IP="$2"
if ! command -v cephadm >/dev/null; then
  curl -fsSL -o /usr/local/sbin/cephadm "https://download.ceph.com/rpm-$RELEASE/el9/noarch/cephadm"
  chmod +x /usr/local/sbin/cephadm
fi
cephadm version 2>/dev/null | tail -1 || true
if [[ -f /etc/ceph/ceph.conf ]]; then
  echo "Cluster bestaat al, bootstrap overgeslagen"
else
  cephadm bootstrap --mon-ip "$MON_IP" --skip-monitoring-stack 2>&1 | tee /root/cephadm-bootstrap.log
fi
EOS
)

log "3/5 cephadm bootstrap op ${NAMES[0]} (${PRIV[0]})"
rsh "$BOOT_PUB" "$BOOT_SCRIPT" "$RELEASE" "${PRIV[0]}"

# ------------------------------------------------------------------ 3. hosts toevoegen
log "4/5 Hosts toevoegen en services uitrollen"
CEPH_PUB=$(rsh "$BOOT_PUB" 'cat /etc/ceph/ceph.pub')
for i in "${!NAMES[@]}"; do
  (( i == 0 )) && continue
  rsh "${PUB[$i]}" 'install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
    grep -qxF "$1" /root/.ssh/authorized_keys || echo "$1" >> /root/.ssh/authorized_keys' "$CEPH_PUB"
done

HOST_ARGS=()
for i in "${!NAMES[@]}"; do HOST_ARGS+=("${NAMES[$i]}=${PRIV[$i]}"); done

CLUSTER_SCRIPT=$(cat <<'EOS'
set -euo pipefail
RGW="$1"; shift
# 'cephadm shell' meldt bij elke aanroep welke fsid/image het gebruikt; die regels filteren we weg.
# </dev/null is essentieel: dit script komt via stdin binnen, en 'cephadm shell' zou de rest ervan opeten.
FILTER='^(Inferring|Using ceph image|quay\.io/ceph)'
ceph()          { cephadm shell -- ceph "$@"          </dev/null 2> >(grep -Ev "$FILTER" >&2); }
radosgw_admin() { cephadm shell -- radosgw-admin "$@" </dev/null 2> >(grep -Ev "$FILTER" >&2); }

N=() ; for hp in "$@"; do N+=("${hp%%=*}"); done
for hp in "$@"; do ceph orch host add "${hp%%=*}" "${hp#*=}"; done

ceph orch apply mon --placement="${N[0]},${N[1]},${N[2]}"
ceph orch apply mgr --placement="${N[0]},${N[1]}"
ceph orch apply osd --all-available-devices
ceph mgr module enable prometheus
ceph config set mgr mgr/prometheus/scrape_interval 5
ceph orch apply ceph-exporter
(( RGW )) && ceph orch apply rgw bench --placement="${N[0]}" --port=8080

echo "Wachten op OSD's (minstens één per host, max. 15 min)..."
want=${#N[@]} up=0
for _ in $(seq 90); do
  up=$(ceph osd stat --format json | grep -o '"num_up_osds": *[0-9]*' | grep -o '[0-9]*$' || echo 0)
  (( up >= want )) && break
  sleep 10
done
echo "OSD's up: $up"
if (( up < want )); then
  echo "WAARSCHUWING: minder OSD's dan hosts. Heeft elke node een lege schijf?" >&2
  ceph orch device ls >&2 || true
fi

if (( RGW )); then
  echo "Wachten op RGW op poort 8080 (max. 5 min)..."
  for _ in $(seq 60); do curl -fsS -o /dev/null http://localhost:8080 && break; sleep 5; done
  info=$(radosgw_admin user info --uid=bench 2>/dev/null || radosgw_admin user create --uid=bench --display-name=bench)
  ( umask 077
    echo "S3_ACCESS_KEY=$(grep -o '"access_key": *"[^"]*"' <<<"$info" | head -1 | cut -d'"' -f4)"
    echo "S3_SECRET_KEY=$(grep -o '"secret_key": *"[^"]*"' <<<"$info" | head -1 | cut -d'"' -f4)"
  ) > /root/ceph-s3.keys
fi
ceph -s
EOS
)

rsh "$BOOT_PUB" "$CLUSTER_SCRIPT" "$RGW" "${HOST_ARGS[@]}"
KEYS=""
(( RGW )) && KEYS=$(rsh "$BOOT_PUB" 'cat /root/ceph-s3.keys 2>/dev/null || true')

# ------------------------------------------------------------------ 5. samenvatting
log "5/5 Klaar"
if (( RGW )) && [[ -n "$KEYS" ]]; then
  ENV_FILE="$ROOT/ceph-s3.env"
  ( umask 077; { echo "S3_ENDPOINT=${PRIV[0]}:8080"; echo "$KEYS"; } > "$ENV_FILE" )
  echo "S3-gegevens voor warp staan in $ENV_FILE (niet in git)."
fi
cat <<EOF
Dashboard-wachtwoord: zie /root/cephadm-bootstrap.log op ${NAMES[0]}.
Controleer op de monitoring-VM in Prometheus (Status → Targets) dat ceph-mgr en ceph-exporter UP zijn.
EOF
