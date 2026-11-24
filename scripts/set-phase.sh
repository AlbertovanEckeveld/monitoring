#!/usr/bin/env bash
# Wissel de testfase op de MONITORING-VM (niet op de storage-nodes).
#
#   ./scripts/set-phase.sh ceph        # fase 1: cephadm op sue-poc-storage01-04
#   ./scripts/set-phase.sh seaweedfs   # fase 2: na snapshot-revert, SeaweedFS
#   ./scripts/set-phase.sh             # toon huidige fase
#
# Wat het doet:
#   - zet in prometheus/targets/storage-nodes.yml het label system=<fase>
#     (hosts en IP's staan in dat bestand zelf)
#   - zet de targets van het andere systeem uit (*.yml -> *.yml.disabled)
#   - plaatst een Grafana-annotatie (als GRAFANA_URL + GRAFANA_TOKEN gezet zijn, bv. via bench.env)
# Prometheus pikt dit binnen enkele seconden op, zonder reload. Data van de vorige
# fase blijft gewoon bewaard onder het oude label.

set -euo pipefail

# bench.env (gemaakt door setup-monitoring-vm.sh) automatisch inlezen, als die er is
BENCH_ENV="$(cd "$(dirname "$0")/.." && pwd)/bench.env"
if [[ -f "$BENCH_ENV" ]]; then set -a; . "$BENCH_ENV"; set +a; fi

DIR="$(cd "$(dirname "$0")/.." && pwd)/prometheus/targets"

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

# Alleen het label 'system' omzetten, atomair (Prometheus leest nooit een half bestand)
TMP="$(mktemp "$DIR/.storage-nodes.XXXXXX")"
sed -E -e "s/system: *(ceph|seaweedfs)/system: $PHASE/" \
       -e "s/^# Huidige fase:.*/# Huidige fase: $PHASE/" "$DIR/storage-nodes.yml" > "$TMP"
chmod 644 "$TMP"
mv "$TMP" "$DIR/storage-nodes.yml"

echo "Fase: $PHASE"
echo "  aan: ${ON[*]}   uit: ${OFF[*]}"
echo "  storage-nodes: $(grep -c 'instance:' "$DIR/storage-nodes.yml") hosts, system=$PHASE"

if [[ -z "${NO_ANNOTATION:-}" && -n "${GRAFANA_URL:-}" && -n "${GRAFANA_TOKEN:-}" ]]; then
  curl -fsS -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" \
    -X POST "$GRAFANA_URL/api/annotations" \
    --data-binary "{\"time\":$(( $(date +%s) * 1000 )),\"tags\":[\"phase\",\"$PHASE\"],\"text\":\"Fase: $PHASE\"}" \
    >/dev/null && echo "  Grafana-annotatie geplaatst" || echo "  WAARSCHUWING: annotatie mislukt" >&2
fi

echo "Controleer: http://localhost:9090/targets"
