#!/usr/bin/env bash
# Haalt de officiële Ceph- en SeaweedFS-dashboards op en zet ze klaar voor provisioning.
# Draai op de monitoring-VM vanuit de map monitoring/:
#   ./scripts/fetch-dashboards.sh [ceph-branch]      # standaard: squid
# Kies de branch die past bij je Ceph-versie (reef, squid, tentacle, ...).
set -euo pipefail

CEPH_BRANCH="${1:-squid}"
CEPH_BASE="https://raw.githubusercontent.com/ceph/ceph/${CEPH_BRANCH}/monitoring/ceph-mixin/dashboards_out"
SWFS_URL="https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/other/metrics/grafana_seaweedfs.json"
DIR="$(cd "$(dirname "$0")/.." && pwd)/grafana/dashboards"

CEPH_DASHBOARDS=(
  ceph-cluster hosts-overview host-details
  osds-overview osd-device-details
  pool-overview pool-detail
  radosgw-overview radosgw-detail
  cephfs-overview
)

# Vervangt ${DS_...}-placeholders (van grafana.com-exports) door onze datasource-uid.
fix_datasource() {
  jq 'del(.__inputs, .__requires)' "$1" \
    | sed -E 's/\$\{DS_[A-Za-z0-9_]+\}/prometheus/g' > "$1.tmp" && mv "$1.tmp" "$1"
}

mkdir -p "$DIR/ceph" "$DIR/seaweedfs"

for d in "${CEPH_DASHBOARDS[@]}"; do
  echo "Ceph: $d"
  if curl -fsSL "$CEPH_BASE/$d.json" -o "$DIR/ceph/$d.json"; then
    fix_datasource "$DIR/ceph/$d.json"
  else
    echo "  niet gevonden op branch $CEPH_BRANCH, overgeslagen" >&2
    rm -f "$DIR/ceph/$d.json"
  fi
done

echo "SeaweedFS: grafana_seaweedfs"
curl -fsSL "$SWFS_URL" -o "$DIR/seaweedfs/seaweedfs.json"
fix_datasource "$DIR/seaweedfs/seaweedfs.json"

echo "Klaar. Grafana pikt de bestanden binnen 30 seconden op."
