# Ceph vs SeaweedFS – monitoring-stack

```
monitoring/
├── docker-compose.yml          # monitoring-VM (= load-generator): Prometheus, Grafana, Pushgateway, Loki, node_exporter
├── .env.example                # Grafana-wachtwoord, retentie
├── prometheus/
│   ├── prometheus.yml          # scrape-jobs
│   ├── targets/*.yml           # hostnamen (live herladen); *.yml.disabled = andere fase
│   │   └── storage-nodes.yml   # gegenereerd door scripts/set-phase.sh
│   └── rules/compare.yml       # recording rules per 'system' (incl. write amplification)
├── grafana/
│   ├── provisioning/           # datasources + dashboard-provider
│   └── dashboards/
│       ├── vergelijking/       # Ceph vs SeaweedFS naast elkaar
│       ├── ceph/               # via scripts/fetch-dashboards.sh
│       └── seaweedfs/          # via scripts/fetch-dashboards.sh
├── loki/loki.yml
├── nodes/                      # agents voor de storage-nodes
│   ├── docker-compose.yml      # node_exporter + Grafana Alloy
│   ├── config.alloy
│   ├── setup-node.sh           # storage-node in één keer opzetten
│   └── set-phase.sh            # SYSTEM-label wisselen + agents (her)starten
└── scripts/
    ├── setup-monitoring-vm.sh  # monitoring-VM in één keer opzetten
    ├── set-phase.sh            # fase wisselen: ceph | seaweedfs
    ├── fetch-dashboards.sh     # officiële Ceph/SeaweedFS-dashboards ophalen
    └── run-bench.sh            # benchmark + Grafana-annotatie + Pushgateway
```

## 1. Monitoring-VM (is ook de load-generator)

De benchmarks draaien op de monitoring-VM zelf. De node_exporter van deze VM krijgt het label
`system=loadgen`. Daaruit komt het client-verkeer voor de write amplification.

Eén commando zet alles op:
- docker, chrony en fio;
- `.env` met een willekeurig wachtwoord;
- de dashboards en de testfase;
- de stack;
- een Grafana-token (`bench.env`);
- de firewall-poorten.

Je kunt het veilig opnieuw draaien.

```bash
sudo ./scripts/setup-monitoring-vm.sh
```

Opties: `--phase ceph|seaweedfs`, `--ceph-branch squid`, `--hostname <naam>`, `--skip-dashboards`.

- Grafana: `http://<vm>:3000`, Prometheus: `:9090`, Pushgateway: `:9091`
- Controleer in Prometheus onder **Status → Targets** dat alles `UP` is.
- De monitoring-VM wordt **nooit** teruggezet naar een snapshot. Daar staan de meetdata van beide fases.

## 2. Testverloop: dezelfde 4 hosts, eerst Ceph, dan SeaweedFS

De hosts `sue-poc-storage01` t/m `04` draaien de systemen **na elkaar**. Het label
`system` van deze hosts wordt per fase gezet met `scripts/set-phase.sh`. De metrics van
Ceph blijven daardoor gewoon bewaard onder `system="ceph"` als je overstapt.

### Stap 0 – Basis-image (vóór de snapshot)

Kopieer de map `nodes/` naar elke storage-node en zet de node op. Vanaf de monitoring-VM bijvoorbeeld:
```bash
MON=$(hostname -f)
for h in sue-poc-storage01 sue-poc-storage02 sue-poc-storage03 sue-poc-storage04; do
  scp -r nodes "$h":~/ && ssh -t "$h" "sudo ~/nodes/setup-node.sh ceph $MON"
done
```
`setup-node.sh` installeert docker en chrony, schrijft `.env` en opent de poorten 9100 en 9324-9327.
Het controleert ook dat poort 9100 vrij is en start node_exporter en Alloy.

Controleer dat de nodes `UP` zijn in Prometheus. **Maak daarna de snapshot.** Zo hebben
beide systemen exact dezelfde node_exporter en hoeven de agents na de revert niet opnieuw te worden geïnstalleerd.

### Stap 1 – Ceph (cephadm)

Monitoring-VM: `./scripts/set-phase.sh ceph` (staat al zo als je net begonnen bent).

```bash
cephadm bootstrap --mon-ip <ip-storage01> --skip-monitoring-stack   # GEEN eigen node-exporter op 9100
ceph orch host add sue-poc-storage02 <ip>   # ... t/m 04
ceph orch apply mgr --placement="sue-poc-storage01,sue-poc-storage02"   # komt overeen met targets/ceph-mgr.yml
ceph orch apply osd --all-available-devices
ceph mgr module enable prometheus
ceph config set mgr mgr/prometheus/scrape_interval 5
ceph orch apply ceph-exporter
```
Heb je al gebootstrapt zonder `--skip-monitoring-stack`? Voer dan `ceph orch rm node-exporter`
uit (en eventueel `prometheus`, `grafana` en `alertmanager`), anders bezet cephadm poort 9100.

Draai de tests met `./scripts/run-bench.sh ceph <testnaam> -- ...` (zie §3).

### Stap 2 – Snapshot terugzetten, SeaweedFS

1. Zet de 4 storage-nodes terug naar de snapshot. **De monitoring-VM niet terugzetten.**
2. Monitoring-VM: `./scripts/set-phase.sh seaweedfs`.
   Dit schakelt de Ceph-targets uit, de SeaweedFS-targets in en zet de storage-nodes op `system="seaweedfs"`.
3. Op elke storage-node: `cd nodes && ./set-phase.sh seaweedfs`.
   Dit zet de klok gelijk (na een revert loopt die achter) en het log-label in Loki.
4. Installeer SeaweedFS en start elk component met `-metricsPort`. De poorten en de verdeling over de hosts staan in
   `prometheus/targets/seaweedfs.yml` (master 01-03, volume 01-04, filer + s3 op 01). Pas dat bestand aan als jullie het anders uitrollen.
5. Draai dezelfde tests met `./scripts/run-bench.sh seaweedfs <testnaam> -- ...`.

### Vergelijken

Let op: de monitoring-VM genereert de load en verwerkt tegelijk de metrics en logs.
Kijk tijdens zware runs in het vergelijkingsdashboard naar de CPU van `loadgen`. Zit die
tegen 100%, dan meet je de load-generator en niet het storagesysteem.

Omdat de fases na elkaar lopen, zie je in de tijdgrafieken per tijdvak maar één systeem.
Vergelijk ze zo:
- **Resultatentabellen** (Pushgateway) tonen alle runs van beide systemen naast elkaar.
- **Annotaties**: elke run is een regio met als tags `system` en `testnaam`. De faseovergang heeft de tag `phase`.
  Klik een regio aan om in te zoomen op precies die run.

## 3. Benchmarken

`run-bench.sh` leest `bench.env` (naast `scripts/`) automatisch in. Dat bestand is
gemaakt door `setup-monitoring-vm.sh`. Op de monitoring-VM:

```bash
./scripts/run-bench.sh ceph put-1MiB-c32 -- \
  warp put --host=rgw1:8080 --access-key="$AK" --secret-key="$SK" \
    --obj.size=1MiB --concurrent=32 --duration=5m --benchdata=results/ceph_put-1MiB-c32
```

Elke run krijgt:
- een **annotatie-regio** in het vergelijkingsdashboard,
- een **logbestand** in `results/`,
- de **duur en status** in de Pushgateway.

Bij fio (`--fio-json`) worden ook de throughput, IOPS en p50/p99/p99.9-latency gepusht en komen ze in de resultatentabel.

De samenvatting van warp wordt niet automatisch geparsed: het outputformaat verschilt per warp-versie. Gebruik `warp analyze results/<bestand>.csv.zst` en bewaar de output.
