#!/usr/bin/env bash
# Wissel de testfase op de MONITORING-VM (niet op de storage-nodes).
#
#   ./scripts/set-phase.sh ceph        # fase 1: cephadm op sue-poc-storage01-04
#   ./scripts/set-phase.sh seaweedfs   # fase 2: na snapshot-revert, SeaweedFS
#   ./scripts/set-phase.sh             # toon huidige fase
#
# Wat het doet:
#   - schrijft prometheus/targets/storage-nodes.yml met system=<fase>
#   - zet de targets van het andere systeem uit (*.yml -> *.yml.disabled)
#   - plaatst een Grafana-annotatie (als GRAFANA_URL + GRAFANA_TOKEN gezet zijn, bv. via bench.env)
# Prometheus pikt dit binnen enkele seconden op, zonder reload. Data van de vorige
# fase blijft gewoon bewaard onder het oude label.
#
# Omgevingsvariabelen:
#   STORAGE_NODES   standaard "sue-poc-storage01 sue-poc-storage02 sue-poc-storage03 sue-poc-storage04"
set -euo pipefail

# bench.env (gemaakt door setup-monitoring-vm.sh) automatisch inlezen, als die er is
BENCH_ENV="$(cd "$(dirname "$0")/.." && pwd)/bench.env"
if [[ -f "$BENCH_ENV" ]]; then set -a; . "$BENCH_ENV"; set +a; fi

DIR="$(cd "$(dirname "$0")/.." && pwd)/prometheus/targets"
STORAGE_NODES="${STORAGE_NODES:-sue-poc-storage01 sue-poc-storage02 sue-poc-storage03 sue-poc-storage04}"

CEPH_FILES=(ceph-mgr ceph-exporter)
SWFS_FILES=(seaweedfs)

if [[ $# -eq 0 ]]; then
  grep -m1 '^# Huidige fase:' "$DIR/storage-nodes.yml" 2>/dev/null || echo "Nog geen fase gezet"
  exit 0
fi

PHASE="$1"
case "$PHASE" in
  ceph)      ON=("${CEPH_FILES[@]}"); OFF=("${SWFS_FILES[@]}") ;;
  seaweedfs) ON=("${SWFS_FILES[@]}"); OFF=("${CEPH_FILES[@]}") ;;
  *) echo "Gebruik: $0 ceph|seaweedfs" >&2; exit 1 ;;
esac

enable()  { [[ -f "$DIR/$1.yml.disabled" ]] && mv "$DIR/$1.yml.disabled" "$DIR/$1.yml" || true; }
disable() { [[ -f "$DIR/$1.yml" ]] && mv "$DIR/$1.yml" "$DIR/$1.yml.disabled" || true; }

for f in "${OFF[@]}"; do disable "$f"; done
for f in "${ON[@]}";  do enable  "$f"; done

# Atomair schrijven, zodat Prometheus nooit een half bestand leest
TARGETS="$(for h in $STORAGE_NODES; do printf "'%s:9100', " "$h"; done)"
TMP="$(mktemp "$DIR/.storage-nodes.XXXXXX")"
cat > "$TMP" <<EOF
# GEGENEREERD door scripts/set-phase.sh – niet met de hand aanpassen.
# Huidige fase: $PHASE
- targets: [${TARGETS%, }]
  labels:
    system: $PHASE
EOF
chmod 644 "$TMP"
mv "$TMP" "$DIR/storage-nodes.yml"

echo "Fase: $PHASE"
echo "  aan: ${ON[*]}   uit: ${OFF[*]}"
echo "  storage-nodes: $STORAGE_NODES"

if [[ -z "${NO_ANNOTATION:-}" && -n "${GRAFANA_URL:-}" && -n "${GRAFANA_TOKEN:-}" ]]; then
  curl -fsS -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" \
    -X POST "$GRAFANA_URL/api/annotations" \
    --data-binary "{\"time\":$(( $(date +%s) * 1000 )),\"tags\":[\"phase\",\"$PHASE\"],\"text\":\"Fase: $PHASE\"}" \
    >/dev/null && echo "  Grafana-annotatie geplaatst" || echo "  WAARSCHUWING: annotatie mislukt" >&2
fi

echo "Controleer: http://localhost:9090/targets"
