#!/usr/bin/env bash
# Wissel de fase op een STORAGE-NODE (sue-poc-storage01-04): zet SYSTEM in .env
# en herstart de agents, zodat de logs in Loki het juiste label 'system' krijgen.
#
#   ./set-phase.sh ceph
#   ./set-phase.sh seaweedfs     # direct na de snapshot-revert
set -euo pipefail
cd "$(dirname "$0")"

PHASE="${1:-}"
[[ "$PHASE" =~ ^(ceph|seaweedfs|loadgen)$ ]] || { echo "Gebruik: $0 ceph|seaweedfs|loadgen" >&2; exit 1; }
[[ -f .env ]] || cp .env.example .env

if grep -q '^SYSTEM=' .env; then
  sed -i "s/^SYSTEM=.*/SYSTEM=$PHASE/" .env
else
  echo "SYSTEM=$PHASE" >> .env
fi

# Na een snapshot-revert loopt de klok achter; eerst gelijkzetten, anders weigert Loki logregels
if command -v chronyc >/dev/null; then
  sudo chronyc makestep >/dev/null || echo "WAARSCHUWING: chronyc makestep mislukt" >&2
fi

docker compose --profile node-exporter up -d
echo "$(hostname): SYSTEM=$PHASE"
