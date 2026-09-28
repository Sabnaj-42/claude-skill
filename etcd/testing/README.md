# KubeDB etcd — manual test plan (runnable)

Everything below was **executed for real** on 2026-09-25 against a live cluster, and every
command is copy-pasteable. The results column is what actually happened, including the failures.
Re-run it after any change to `kubedb.dev/etcd`, `etcd-restic-plugin`, `db-client-go`, the
provisioner's etcd wiring, or the installer's etcd catalog.

- **Cluster used:** single-node k3s v1.36.4 (`~/k3s-80.yaml`), `local-path` StorageClass only.
- **KubeDB:** chart v2026.8.26-rc.2 with `global.featureGates.Etcd=true`, running the **fix builds**
  (see §1.1 — release rc.2 cannot pass most of this plan). etcd 3.6.4 unless stated.
- **Sibling docs:** the build/deploy loop is `../workflows.md`; the
  bug ledger is `../bugs.md`. This file is the *test plan*.

## 0. Scoreboard (2026-09-25)

| Area | Fully passed | Partial / failed / blocked |
|---|---|---|
| Provisioning & CR features (P1–P7) | P1 general, P2 single replica, P4 customization, P7 monitoring | **P3** Ephemeral — bootstrap ok, pod loss crash-loops (BUG 13); **P5** deletionPolicy — `DoNotTerminate` does not block delete (BUG 10); **P6** halt/resume — multi-member never resumes (BUG 12) |
| Ops requests (O1–O14) | O1 Restart, O2 MoveLeader, O3 Compact, O4 Defragment, O5 HorizontalScaling, O6 VerticalScaling (both modes), O7 UpdateVersion, O8 Reconfigure*, O9 RotateAuth, O10 ReconfigureTLS (add/rotate/update/remove), O11 StorageMigration, O14 Restore (via B3) | **O13** RecoverFromQuorumLoss fails (BUG 11); **O12** VolumeExpansion needs a resizable CSI (environment). *O8 has a limitation (F1) |
| Backup / restore (B1–B4) | B1 prerequisites, B3 in-place restore, B4 bootstrap restore — **only after fixes for BUGs 16, 17, 18** | **B2** — the etcd data path passes only after the BUG 14 fix; the archiver-generated backup still fails (BUG 15) |
| Resilience (R1–R9) | R1 leader kill under load, R2 pod loss (disk kept), R4 provisioner kill, R5 etcd-ops kill, R6 one-op-at-a-time, R7 IfReady gate, R8 invalid requests | **R3** lost-disk member (BUG 13); **R9** deleting an in-flight op (BUG 19) |
| Extras (X1–X2) | X1 autoscaler (with metrics-server) | X2 GitOps not tested |

**Bugs found by this run (all reproduced live): BUG 11–19.** BUG 1–10 are from the earlier bring-up
(see `bugs.md`). Fixed and verified here: 14, 16, 17, 18. Open: 10, 11, 12, 13, 15, 19.

---

## 1. Environment

### 1.1 Which builds you must run

Release `rc.2` cannot provision a multi-member cluster or reach `Ready` at all. Use:

| Component | What to run | Needed for |
|---|---|---|
| `kubedb.dev/etcd` | branch `fix-psclient-provisioner-host` (PR kubedb/etcd#4) | almost everything (BUGs 1–9) |
| `kubedb.dev/etcd` | + branch `fix-backup-restore-task-name` (commits `3a07bd4c`, `ce1942d5`) | restore (BUGs 16, 18) |
| `kubedb.dev/db-client-go` | kubedb/db-client-go#267 (vendored into the two builds above) | multi-member bootstrap, health checks |
| `kubedb.dev/etcd-restic-plugin` | branch `fix-appbinding-endpoint-scheme` (commits `0d92022`, `00390f2`) | backup (BUG 14), restore (BUG 17) |

Deploy them with `../workflows.md` (provisioner via vendor splice,
`etcd-ops` as its own Deployment, images side-loaded into k3s). Remember the **PetSet is `OnDelete`**:
a provisioner change reaches running pods only when they are deleted/restarted.

### 1.2 Cluster prerequisites (one-time)

```bash
export KUBECONFIG=$HOME/k3s-80.yaml      # confirm which cluster with the owner first
cd claude-skill/etcd/testing && source lib.sh   # helpers used everywhere below
kubectl create ns demo

# cert-manager: the kubedb chart ships only certificates+issuers CRDs -> install the full CRD set first
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.crds.yaml
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=false
kubectl apply -f manifests/cert-issuers.yaml           # CA chain used by the TLS tests

# etcd-ops is NOT shipped by any chart: deploy it (see workflows.md §0) and give it KubeStash RBAC
kubectl apply -f ../assets/etcd-ops-deploy.yaml
kubectl apply -f manifests/etcd-ops-kubestash-rbac.yaml   # else Restore stalls: "restoresessions ... forbidden"

# a second StorageClass on the same provisioner (StorageMigration target)
kubectl apply -f manifests/storageclass-local-path-2.yaml
```

Optional, only for the tests that need them:

| Needed by | Install |
|---|---|
| P7 monitoring | Prometheus Operator bundle in ns `monitoring` + `manifests/prometheus-minimal.yaml` (§P7) |
| X1 autoscaler | `metrics-server` with `--kubelet-insecure-tls` on k3s (§X1) |
| B1–B4 backup/restore | in-cluster S3 `manifests/s3-server.yaml`, KubeStash (already in the cluster), and the **plugin image** (§B1) |

### 1.3 Conventions used by every test

- **Preflight gate.** Phase `Ready` is *not* evidence. `preflight <db> <n>` checks: `n` voters, none a learner,
  every member healthy, a write on one member readable on another, and equal revisions on all members.
  Run it before a test and after every disruptive step. A failed preflight aborts the test.
- **Canary data.** `load <db> <member> <prefix> <n>` writes `n` keys; `count <db> <member> <prefix>` reads
  how many a member sees. After every op, the canary count must be unchanged on **every** member.
- **No shell in the DB image.** All etcd access is `etcdctl` exec'd directly; `ec`/`ecx` add TLS flags when the
  Etcd has `spec.tls` and root credentials always (`ec` = stdout only, `ecx` = merged, for asserting on errors).
- **One DB per topic.** Tests create `t-*` databases in `demo`. Do not touch `etcd-uv` (long-running TLS canary).
- **Ops requests:** `ops <name> <Type> <db> "<indented spec yaml>"`, then `wait_ops <name> <seconds>`.
  Read `ops_conditions <name>` — the conditions *are* the state machine; a step's `lastTransitionTime` is its timeout clock.

---

## 2. Provisioning and CR features

### P1 — general: create, objects, data, delete   **PASS**

```bash
std_etcd t-general 3            # 3 replicas, Durable 1Gi local-path, WipeOut
wait_phase t-general Ready 300  # PASS: Ready in ~56s
kubectl get pods,pvc,svc,cm,secret,sa,role,rolebinding,pdb,appbinding -n demo | grep t-general
kubectl get petsets.apps.k8s.appscode.com -n demo t-general -o jsonpath='{.spec.updateStrategy.type} {.spec.podManagementPolicy}{"\n"}'
preflight t-general 3
load t-general 0 data 300; for i in 0 1 2; do count t-general $i data; done
```
Expect: 3 pods + 3 PVCs `data-t-general-<n>`; Services `t-general` (2379) and `t-general-pods` (headless,
2379+2380); ConfigMap `t-general-cluster-state`; Secret `t-general-auth` (user `root`); SA/Role/RoleBinding;
PDB `maxUnavailable: 1`; AppBinding `t-general`; PetSet `OnDelete` + `OrderedReady`. Conditions
`ProvisioningStarted, ReplicaReady, AcceptingConnection, Ready, Provisioned = True`, `QuorumLost = False`.
300 keys on every member, identical revision. Bootstrap is 1 → 2 → 3 pods (learner add/promote) — watch
`kubectl get pods -w`. **Keep this cluster: the ops tests below reuse it.**

### P2 — single replica   **PASS**

```bash
std_etcd t-single 1; wait_phase t-single Ready 240      # ~35s; no PDB is created for 1 member
load t-single 0 s 100
ops t-single-restart Restart t-single "  timeout: 5m"; wait_ops t-single-restart 300;  count t-single 0 s   # 100
ops t-single-up HorizontalScaling t-single "  horizontalScaling:
    replicas: 3
  timeout: 10m"; wait_ops t-single-up 600; count t-single 2 s                                          # 100 on new member
```

### P3 — Ephemeral storage   **PARTIAL** (bootstrap PASS, pod loss FAIL → BUG 13)

```bash
kubectl apply -f - <<'EOF'
apiVersion: kubedb.com/v1alpha2
kind: Etcd
metadata: {name: t-eph, namespace: demo}
spec: {version: "3.6.4", replicas: 3, storageType: Ephemeral, storage: {resources: {requests: {storage: 1Gi}}}, deletionPolicy: WipeOut}
EOF
wait_phase t-eph Ready 240; preflight t-eph 3; load t-eph 0 e 50
kubectl get pvc -n demo | grep -c t-eph                                            # 0
kubectl get pod -n demo t-eph-0 -o jsonpath='{.spec.volumes[?(@.name=="data")]}'   # emptyDir with sizeLimit
```
PASS: Ready ~40s, `emptyDir` (sizeLimit 1Gi), 0 PVCs, 50 keys replicated.
**FAIL (BUG 13):** `kubectl delete pod -n demo t-eph-1` → the recreated pod (empty emptyDir) crash-loops
forever with `tocommit(N) is out of range [lastIndex(0)]. Was the raft log corrupted, truncated, or lost?`;
DB goes `Critical`; a queued `Restart` op sits `Pending`. On Ephemeral storage *any* pod recreation
(eviction, drain, the operator's own Restart) breaks the cluster. Clean up: `kubectl delete etcd -n demo t-eph`.

### P4 — customization pass-through   **PASS**

```bash
kubectl apply -f manifests/etcd-custom.yaml         # extra flags, env, sidecar, pod labels, Service template
wait_phase t-custom Ready 300; preflight t-custom 3
etcd_flags t-custom 0 'election|heartbeat|max-request'          # the 3 flags reach the container (last flag wins)
kubectl get pod -n demo t-custom-0 -o jsonpath='{.spec.containers[*].name} team={.metadata.labels.team}{"\n"}'
kubectl get svc -n demo t-custom -o jsonpath='{.spec.type} {.spec.ports[0].nodePort}{"\n"}'   # NodePort
kubectl logs -n demo t-custom-0 -c etcd | grep -m2 -oE '"heartbeat-interval":"[^"]*"|"election-timeout":"[^"]*"'
```
Proof the flags took effect at runtime: etcd's own log prints `heartbeat-interval: 200ms`, `election-timeout: 2s`.
Custom env `MY_CUSTOM_ENV` is present, the `sidecar` container runs (any container **not** named `etcd` is passed
through), pod labels/annotations are applied, and `serviceTemplates[alias=primary]` turns the client Service into a NodePort.

### P5 — deletionPolicy   **PARTIAL**

Use 1-replica clusters (`replicas: 1`, policy varied); write ~20 keys first.

| Policy | Do | Result |
|---|---|---|
| `Delete` | `kubectl delete etcd t-del` | **PASS** — only `t-del-auth` Secret remains (pods, PVC, svc, cm, RBAC, AppBinding gone) |
| `Halt` | delete, then re-`apply` the **same** CR | **PASS** — PVC `data-t-halt-0` + auth Secret retained; re-created CR → Ready in 30s with all 30 keys |
| `WipeOut` | delete | **PASS** — nothing left (`left <db>` prints empty) |
| `DoNotTerminate` | patch policy, `kubectl delete etcd` | **PARTIAL (BUG 10)** — delete is **not blocked**: CR and pods are removed. The shared library treats it like `Halt`, so the PVC and auth Secret survive and data is recoverable. Real protection is the (unserved) validating webhook |

Clean up leftover PVC/Secret from `Halt`/`Delete`/`DoNotTerminate` runs by hand.

### P6 — halt / resume   **PARTIAL**

```bash
kubectl patch etcd -n demo t-halted --type=merge -p '{"spec":{"halted":true,"deletionPolicy":"Halt"}}'   # BOTH fields (see note)
wait_phase t-halted Halted 120        # PASS ~15s: pods, PetSet, Services, PDB removed; 3 PVCs + auth Secret kept
kubectl patch etcd -n demo t-halted --type=merge -p '{"spec":{"halted":false}}'
wait_phase t-halted Ready 300         # 1 replica: PASS.  3 replicas: FAIL (BUG 12) - stays NotReady
```
- **Note:** `halted: true` alone is refused (`can't halt db. spec.deletionPolicy is not Halt`). The mutating webhook that
  would flip the policy for you is unserved (BUG 10), so set both.
- **BUG 12:** resuming a **multi-member** cluster deadlocks. `EnsurePetSet` re-creates the PetSet with the 1-replica
  bootstrap seed, but the retained data dir remembers a 3-member Raft configuration, so pod-0 loops elections
  with 1/3 votes, and the provisioner cannot grow the PetSet (its client hangs — same mechanism as BUG 11).
  Also applies to any "recreate the CR over retained PVCs" of a multi-member cluster.

### P7 — monitoring   **PASS**

```bash
# Prometheus Operator (bundle) + a minimal Prometheus that scrapes every ServiceMonitor
TAG=$(curl -s https://api.github.com/repos/prometheus-operator/prometheus-operator/releases/latest | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])')
kubectl create ns monitoring
curl -sL https://github.com/prometheus-operator/prometheus-operator/releases/download/$TAG/bundle.yaml | sed 's/namespace: default/namespace: monitoring/g' | kubectl apply --server-side -f -
kubectl apply -f manifests/prometheus-minimal.yaml

kubectl patch etcd -n demo t-custom --type=merge -p '{"spec":{"monitor":{"agent":"prometheus.io/operator","prometheus":{"serviceMonitor":{"labels":{"release":"test"},"interval":"10s"}}}}}'
kubectl get svc -n demo t-custom-stats -o jsonpath='{.spec.ports[*].name}:{.spec.ports[*].port}->{.spec.ports[*].targetPort}{"\n"}'   # metrics:2381->metrics
kubectl get servicemonitor -n demo t-custom-stats -o jsonpath='{.spec.endpoints[0].path} {.spec.endpoints[0].scheme} {.spec.endpoints[0].port}{"\n"}'  # /metrics http metrics
kubectl port-forward -n monitoring pod/prometheus-test-0 19090:9090 &
q() { curl -s --data-urlencode "query=$1" http://127.0.0.1:19090/api/v1/query | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(len(r),[(x["metric"].get("pod"),x["value"][1]) for x in r])'; }
q 'up{namespace="demo",service="t-custom-stats"}'                  # 3 series, all 1
q 'etcd_server_has_leader{namespace="demo",service="t-custom-stats"}'   # all 1
q 'etcd_server_is_leader{namespace="demo",service="t-custom-stats"}'    # exactly one 1
```
PASS: stats Service + ServiceMonitor created; Prometheus scrapes all 3 members; exactly one leader. Metrics are **always
plain http** (even with `spec.tls`) and there is **no exporter sidecar**. Removing `spec.monitor` deletes the ServiceMonitor but
**leaves the `<db>-stats` Service behind** (minor orphan).

---

## 3. Ops requests (run on `t-general` from P1, 3 members, 300 keys under `data/`)

After **every** op: `preflight t-general 3` and `count t-general <each member> data` (= 300).

### O1 — Restart   **PASS** (50s)
```bash
ops t-restart Restart t-general "  timeout: 10m"; wait_ops t-restart 300
ops_conditions t-restart | grep -E "EvictPod|MoveLeader"
```
Followers are evicted first (`EvictPod--<pod>`), then `MoveLeader--<leader>`, then the old leader last. All pod UIDs change.

### O2 — MoveLeader   **PASS** (5s each)
```bash
L0=$(leader_pod t-general)
ops t-ml MoveLeader t-general "  moveLeader: {}
  timeout: 5m"; wait_ops t-ml 120; leader_pod t-general            # different from $L0
TGT=$(members t-general | awk '{print $1}' | grep -v "^$(leader_pod t-general)$" | head -1)   # any member that is NOT the current leader
ops t-ml2 MoveLeader t-general "  moveLeader:
    newLeader: $TGT
  timeout: 5m"; wait_ops t-ml2 120; leader_pod t-general           # == $TGT
```

### O3 — Compact   **PASS** (5s)
```bash
ec t-general 0 put cmp/k v1 >/dev/null; R1=$(ec t-general 0 get cmp/k -w json | python3 -c 'import json,sys;print(json.load(sys.stdin)["kvs"][0]["mod_revision"])')
for v in v2 v3 v4 v5; do ec t-general 0 put cmp/k $v >/dev/null; done
ops t-compact Compact t-general "  timeout: 5m"; wait_ops t-compact 120
ecx t-general 0 get cmp/k --rev=$R1 | grep -i compacted           # "required revision has been compacted" on EVERY member
ec t-general 0 get cmp/k --print-value-only                       # v5 (latest still there)
# explicit revision:  compact: {revision: <N>}
```

### O4 — Defragment   **PASS** (5s)
```bash
BIG=$(head -c 60000 /dev/zero | tr '\0' x); for i in $(seq 1 40); do ec t-general 0 put bloat/k$i "$BIG" >/dev/null; done
ec t-general 0 del bloat/ --prefix >/dev/null
ops t-compact2 Compact t-general "  timeout: 5m"; wait_ops t-compact2 120
for i in 0 1 2; do ec t-general $i endpoint status -w json | python3 -c 'import json,sys;s=json.load(sys.stdin)[0]["Status"];print(s["dbSize"]//1024,"KB file,",s["dbSizeInUse"]//1024,"KB in use")'; done   # ~2760 KB file
ops t-defrag Defragment t-general "  timeout: 10m"; wait_ops t-defrag 300
# again: file shrinks to ~48 KB on all three
```
Conditions show `EtcdDefragmented--<pod>` + `EtcdClusterHealthy--<pod>` per member (leader last) and `EtcdAlarmCleared`.

### O5 — HorizontalScaling   **PASS**
```bash
hs() { ops "$1" HorizontalScaling t-general "  horizontalScaling:
    replicas: $2
  timeout: 10m"; wait_ops "$1" 600; sleep 5
  echo "members=$(members t-general | wc -l) pods=$(kubectl get pods -n demo -l app.kubernetes.io/instance=t-general --no-headers | wc -l) pvcs=$(kubectl get pvc -n demo --no-headers | grep -c t-general) pdb=$(kubectl get pdb -n demo t-general -o jsonpath='{.spec.maxUnavailable}' 2>/dev/null)  canary-on-newest=$(count t-general $(( $2 - 1 )) data)"; }
hs hs5 5; hs hs3 3; hs hs1 1; hs hs3b 3        # 35s / 10s / 10s / 35s
```
PASS: voters = pods = PVCs at each step; PDB `maxUnavailable` 2 / 1 / *(none)* / 1; canary readable from the newest
member; scale-down removes the highest ordinal from etcd first, then shrinks the PetSet, then **deletes that ordinal's PVC**;
re-scaling to a previously removed ordinal works.

### O6 — VerticalScaling   **PASS**
```bash
ops vs-restart VerticalScaling t-general "  verticalScaling:
    mode: Restart
    etcd:
      resources:
        requests: {cpu: 300m, memory: 512Mi}
        limits: {cpu: 500m, memory: 1Gi}
  timeout: 10m"; wait_ops vs-restart 600                       # 50s
for i in 0 1 2; do resources t-general $i; done                  # exact requested resources, NEW pod UIDs

ops vs-inplace VerticalScaling t-general "  verticalScaling:
    mode: InPlace
    etcd:
      resources:
        requests: {cpu: 400m, memory: 600Mi}
        limits: {cpu: 600m, memory: 1200Mi}
  timeout: 10m"; wait_ops vs-inplace 300                       # 10s
for i in 0 1 2; do resources t-general $i; done                  # new resources, SAME uid, restarts=0
```
Restart mode replaces every pod; InPlace uses `pods/resize` (`RequestInPlaceResize--<pod>` + `CheckInPlaceResizeSettled--<pod>`)
with no pod recreation.

### O7 — UpdateVersion   **PASS**
```bash
ops downgrade UpdateVersion t-general "  updateVersion:
    targetVersion: \"3.5.21\"
  timeout: 3m"                        # PASS: phase Failed 'downgrades are not supported'; DB untouched, no Paused leak
std_etcd t-upgrade 3 3.5.21; wait_phase t-upgrade Ready 300; load t-upgrade 0 up 200
ops upgrade UpdateVersion t-upgrade "  updateVersion:
    targetVersion: \"3.6.4\"
  timeout: 15m"; wait_ops upgrade 900                          # 50s
for i in 0 1 2; do ec t-upgrade $i endpoint status -w json | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["Status"]["version"])'; count t-upgrade $i up; done   # 3.6.4, 200
kubectl delete etcd -n demo t-upgrade; left t-upgrade            # WipeOut leaves nothing
```

### O8 — Reconfigure   **PASS** with a limitation
```bash
ops reconf Reconfigure t-general "  configuration:
    tuning:
      quotaBackendBytes: 2147483648
      autoCompactionMode: periodic
      autoCompactionRetention: \"2h\"
      snapshotCount: 5000
  timeout: 10m"; wait_ops reconf 600                           # 50s (a rolling restart: knobs are flags)
etcd_flags t-general 0 'quota|compaction|snapshot'               # the 4 flags
ec t-general 0 endpoint status -w json | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["Status"]["dbSizeQuota"]//1048576,"MiB")'   # 2048
```
**Limitation F1:** `configuration.removeCustomConfig: true` is accepted and rolls the cluster but **does not unset tuning knobs**
(it clears only `configSecret`); no ops request can unset a knob. **Workaround (verified):**
`kubectl patch etcd -n demo t-general --type=json -p='[{"op":"remove","path":"/spec/configuration"}]'` — the PetSet template is
clean immediately but pods are `OnDelete`, so then run a `Restart` op to apply it.

### O9 — RotateAuth   **PASS**
```bash
OLD=$(etcd_pw t-general); ecx t-general 0 auth status | grep Status        # false: RBAC is OFF until the first RotateAuth
ops rot RotateAuth t-general "  timeout: 10m"; wait_ops rot 300          # 5s. This ENABLES etcd RBAC.
NEW=$(etcd_pw t-general); ecx t-general 0 auth status | grep Status        # true
kubectl exec -n demo t-general-0 -- etcdctl --user root:"$OLD" get data/key-1     # "authentication failed"
kubectl exec -n demo t-general-0 -- etcdctl get data/key-1                        # "user name is empty"
kubectl get secret -n demo t-general-auth -o jsonpath='{.data}' | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin)))'   # password, password.prev, username, username.prev
```
**Then prove other ops still work with RBAC on** (this is where BUG 3's promotion fallback matters):
scale 3→4 (20s, canary on the new member), `Restart` (65s), scale 4→3 (10s), all `Successful`, preflight OK.

**User-supplied secret** (RBAC already on):
```bash
kubectl create secret generic t-user-auth -n demo --type=kubernetes.io/basic-auth --from-literal=username=root --from-literal=password='UserSupplied-Pw-2026'
ops rot2 RotateAuth t-general "  authentication:
    secretRef: {kind: Secret, name: t-user-auth}
  timeout: 5m"; wait_ops rot2 300
kubectl get etcd -n demo t-general -o jsonpath='{.spec.authSecret}'      # name t-user-auth, externallyManaged true, activeFrom set
```
The supplied password works; the previous generated one is rejected. (`etcd_pw`/`ec` follow `spec.authSecret.name`.)

### O10 — ReconfigureTLS   **PASS** (all four; run on the RBAC-enabled cluster with data)
```bash
peers() { ec t-general 0 member list | awk -F', ' '{print $4}' | sed 's/\.t-general-pods.*//' | sort | tr '\n' ' '; }
ops tls-add ReconfigureTLS t-general "  tls:
    issuerRef: {apiGroup: cert-manager.io, kind: Issuer, name: etcd-ca-issuer}
  timeout: 15m"; wait_ops tls-add 900        # 91s
peers                                         # https://t-general-0 ... : every registered PEER URL flipped to https
kubectl get secret -n demo | grep -E 't-general-(server|peer|client)-cert'            # 3 secrets; client cert CN=root
kubectl exec -n demo t-general-0 -- etcdctl --endpoints=http://127.0.0.1:2379 endpoint health   # refused (plaintext port is gone)

serial() { kubectl get secret -n demo t-general-$1-cert -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial; }
serial server; serial peer; serial client     # remember
ops tls-rot ReconfigureTLS t-general "  tls:
    rotateCertificates: true
  timeout: 15m"; wait_ops tls-rot 900        # 55s; all three serials change

ops tls-upd ReconfigureTLS t-general "  tls:
    certificates:
    - alias: server
      subject: {organizations: [acme-corp], organizationalUnits: [db-platform]}
  timeout: 15m"; wait_ops tls-upd 900        # 61s; server cert subject becomes O=acme-corp, OU=db-platform

ops tls-rm ReconfigureTLS t-general "  tls:
    remove: true
  timeout: 15m"; wait_ops tls-rm 900         # 81s; spec.tls cleared, peer URLs back to http, Certificate objects deleted
```
After each: `preflight t-general 3` and canary intact. Observation: the three `<db>-{server,peer,client}-cert` **Secrets remain**
after TLS removal (only deleted with the DB). The roll needs the dual-view quorum gates and the per-member `MemberUpdate`
peer-URL sync (BUG 9) — without them enabling TLS partitions the cluster.

### O11 — StorageMigration   **PASS** (167s)
```bash
kubectl apply -f manifests/storageclass-local-path-2.yaml
ops migrate StorageMigration t-general "  migration:
    storageClassName: local-path-2
  timeout: 30m
  apply: IfReady"; wait_ops migrate 1500
kubectl get pvc -n demo | grep t-general                         # all three now local-path-2
kubectl get etcd -n demo t-general -o jsonpath='{.spec.storage.storageClassName}'                       # local-path-2
kubectl get petsets.apps.k8s.appscode.com -n demo t-general -o jsonpath='{.spec.volumeClaimTemplates[0].spec.storageClassName}'
```
PASS: PVCs re-created on the new class, CR + PetSet template updated, Raft state survived the volume copy (300 keys on every member).

### O12 — VolumeExpansion   **BLOCKED (environment)**
```bash
ops expand VolumeExpansion t-general "  volumeExpansion:
    mode: Online
    etcd: 2Gi
  timeout: 4m"        # Offline mode: scales the PetSet to 0 first
```
On `local-path` (no volume resizer) the op patches all three PVC requests to 2Gi, waits for `status.capacity` (never changes) and
**Failed cleanly at the timeout**: DB left `Ready`, **not** paused, PetSet/pods untouched, preflight OK. **A real pass needs a
resizable CSI (longhorn, ...).**

### O13 — RecoverFromQuorumLoss   **FAIL — BUG 11** (procedure documented for when it is fixed)
To make the loss *permanent* (Kubernetes recreates deleted pods within seconds and etcd then self-heals — finding P-F2 — so you must stop that):
```bash
std_etcd t-quorum 3; wait_phase t-quorum Ready 300; load t-quorum 0 q 150
kubectl scale statefulset kubedb-kubedb-provisioner -n kubedb --replicas=0          # NOTE: a StatefulSet, not a PetSet
kubectl scale petsets.apps.k8s.appscode.com t-quorum -n demo --replicas=1           # removes pods 2,1 and their PVCs
kubectl scale statefulset kubedb-kubedb-provisioner -n kubedb --replicas=1
# EXPECTED (once fixed): QuorumLost=True within ~1 min.   OBSERVED: never raised; DB just NotReady/AcceptingConnection=False
ops recover RecoverFromQuorumLoss t-quorum "  apply: Always
  recoverFromQuorumLoss: {}
  timeout: 20m"
# I only ever ran it with {} (and QuorumLost hand-stamped) - it stalls at survivor resolution (BUG 11), so the steps below are
# the DESIGN's expectation (etcd/DESIGN.md §10), NOT something this run observed:
#   resolve survivor -> hold at EtcdQuorumLossAwaitingConfirmation until spec.recoverFromQuorumLoss.confirmMember == <pod name>
#   -> discard stale members -> --force-new-cluster boot -> single member healthy -> flag removed -> volumes reclaimed
#   -> provisioner regrows to 3; all 150 keys present.
```
**BUG 11:** the credentialed client can't even be created without a Raft leader (clientv3 sends `Authenticate`, which needs a leader),
so `health.go` logs `failed to create etcd client ... context deadline exceeded` and never reaches its `QuorumLost` branch, and
`recover_from_quorum_loss.go:220` fails the same way. Proof: `etcdctl --user root:… endpoint status` hangs 3s; without `--user` it
answers in 0.15s with `errors=['etcdserver: no leader']`. With `QuorumLost` hand-stamped the op *is admitted*
(`EtcdQuorumLossAdmitted=True`) but survivor resolution never completes. The rest of the procedure is **untested**.

### O14 — Restore   see B3.

---

## 4. Backup and restore (KubeStash)

### B1 — prerequisites   **PASS**

1. **Plugin image.** `ghcr.io/kubedb/etcd-restic-plugin:v0.1.0-rc.2_<etcd-version>` is **not pullable** (private/unpublished).
   Build it from the plugin branch and side-load it under exactly that tag:
   ```bash
   cd ~/go/src/kubedb.dev/etcd-restic-plugin.worktrees/<wt>          # branch fix-appbinding-endpoint-scheme
   GOCACHE=/tmp/gocache-restic make container-3.6.4_linux_amd64      # (add GO_VERSION=1.25 if golang-dev:1.25.5 isn't pullable)
   docker tag ghcr.io/kubedb/etcd-restic-plugin:fix-appbinding-endpoint-scheme_3.6.4_linux_amd64 ghcr.io/kubedb/etcd-restic-plugin:v0.1.0-rc.2_3.6.4
   # then side-load (workflows.md §3): docker save -> http server -> `k3s ctr images rm` + `import` in the image-importer pod
   ```
2. **S3 store.** MinIO's community images are gone (`quay.io/minio` → 401, `docker.io/minio` → pull denied). Use
   `manifests/s3-server.yaml` (Scality cloudserver + an `aws-cli` Job creating bucket `etcd-backups`; needs `ENDPOINT=s3.s3.svc`
   and path-style addressing or it answers `InvalidURI`).
3. **KubeStash resources:** `kubectl apply -f manifests/kubestash-backup.yaml` (Secrets, BackupStorage, RetentionPolicy, EtcdArchiver).
   PASS when `kubectl get backupstorage -n demo s3-storage` is `Ready` with `BackendInitialized=True`.
   The `etcd-addon` (tasks `etcd-backup`, `etcd-restore`, `manifest-backup`, `manifest-restore`) ships with the KubeStash catalog.

### B2 — backup   **PASS** (etcd data path) / **FAIL** (archiver flow, BUGs 14/15)

```bash
# (a) archiver flow — what the docs describe
kubectl label etcd -n demo t-general archiver=true --overwrite
kubectl patch etcd -n demo t-general --type=merge -p '{"spec":{"archiver":{"ref":{"name":"etcd-archiver","namespace":"demo"}}}}'
kubectl get backupconfiguration -n demo          # t-general-archiver: sessions full-backup(etcd-backup+manifest-backup) and manifest-backup
```
The operator generates the BackupConfiguration correctly (Ready, CronJobs created, Repositories `t-general-full`/`t-general-manifest` Ready).
A manual `BackupSession` on it:
- **without the plugin fix:** fails at the first dial — **BUG 14** — `dial tcp: address etcd://t-general.demo.svc:2379/: too many colons in address`
  (the AppBinding's `service.scheme` is `etcd`, the db-type convention; clientv3 needs http/https).
- **with the plugin fix:** the etcd component **Succeeds** (snapshot taken over `http://<svc>:2379` with RBAC on, ~70 kB, restic init + backup to S3,
  `restic check` → no errors), **but the session is marked `Failed`** — **BUG 15**: the bundled `manifest-backup` task answers
  `error: Etcd is not supported`, and restore ignores Failed snapshots. So archiver-driven backups are unusable end to end.

```bash
# (b) WORKAROUND used for everything below: a hand-made etcd-only BackupConfiguration (no manifest task)
kubectl patch etcd -n demo t-general --type=json -p='[{"op":"remove","path":"/spec/archiver"}]'; kubectl label etcd -n demo t-general archiver-
kubectl delete backupconfiguration -n demo t-general-archiver          # F5: it is NOT removed automatically
kubectl apply -f manifests/backupconfig-etcd-only.yaml
ec t-general 0 put backup/marker "before-backup-$(date +%s)"
kubectl apply -f - <<'EOF'
apiVersion: core.kubestash.com/v1alpha1
kind: BackupSession
metadata: {name: etcdonly-backup-1, namespace: demo}
spec:
  invoker: {apiGroup: core.kubestash.com, kind: BackupConfiguration, name: t-general-etcdonly}
  session: full-backup
EOF
kubectl get backupsession,snapshot -n demo          # Succeeded in ~15s
kubectl get repository -n demo t-general-etcdonly-full -o jsonpath='integrity={.status.integrity} snapshots={.status.snapshotCount}{"\n"}'   # true
```
PASS: `Succeeded`, repository `integrity=true`. Note the AppBinding keeps a **stale `caBundle` after TLS removal** (F4), which is why the plugin
chooses http/https from the Etcd object instead.

### B3 — in-place Restore op   **PASS after fixes for BUGs 16, 17, 18**

Mutate data **after** the backup so a correct restore is visible:
```bash
ec t-general 0 del backup/marker; for i in $(seq 1 50); do ec t-general 0 del data/key-$i >/dev/null; done
for i in $(seq 1 20); do ec t-general 0 put after/x$i post-backup >/dev/null; done
ops restore Restore t-general "  apply: Always
  restore:
    fullDBRepository: {name: t-general-etcdonly-full, namespace: demo}
    encryptionSecret: {name: encrypt-secret, namespace: demo}
  timeout: 30m"; wait_ops restore 1800                      # 51s
wait_phase t-general Ready 300
ec t-general 0 get backup/marker --print-value-only          # the pre-backup value is BACK
count t-general 0 data                                       # 300  (incl. the 50 deleted keys)
count t-general 0 after                                      # 0    (post-backup writes are gone)
for i in 0 1 2; do count t-general $i data; done             # 300 300 300 (learners streamed from the restored seed)
kubectl exec -n demo t-general-0 -- etcdctl get data/key-1   # "user name is empty": restored auth store => RBAC still enforced
```
What it does: orphan the PetSet → discard members 1..n → wipe the seed PVC → RestoreSession into the seed PVC → 1-member cluster from the
snapshot → reclaim volumes → provisioner regrows to N. Each of these bugs alone made it fail or silently lose data:

| Bug | Symptom | Fix |
|---|---|---|
| 16 | RestoreSession `Invalid`: `Task etcd-backup-restore of Addon etcd-addon does not exist` (the addon ships `etcd-restore`); the op stalls **after** discarding members and wiping the seed volume | etcd `3a07bd4c` |
| 17 | plugin resolves the Etcd by the RestoreSession *target name* (`data-t-general-0`, a PVC): `etcds.kubedb.com "data-t-general-0" not found`; the Job shows **Completed (exit 0)** while restoring nothing | plugin `00390f2` |
| **18** | **op reports `Successful`, cluster `Ready`, database EMPTY.** The plugin rebuilds `member/` at `/var/lib/etcd/member` but etcd runs with `--data-dir=/var/lib/etcd/data`, so the restored data is ignored and a fresh cluster bootstraps. Verify with a `busybox` pod mounting the PVC: `/v/member` (restored) beside `/v/data/member` (fresh) | etcd `ce1942d5` (`dataDir` task param) |

Also needed: `etcd-ops` must be allowed to create `restoresessions` (`manifests/etcd-ops-kubestash-rbac.yaml`).
**Always verify a restore by reading the data back — the op's own status is not enough.**

### B4 — bootstrap restore (`spec.init.archiver`)   **PASS after fixes for BUGs 16, 18**
```bash
kubectl apply -f manifests/etcd-from-backup.yaml
wait_phase t-boot Ready 300              # 56s, condition SuccessfullyDataRestored=True
ec t-boot 0 get backup/marker --print-value-only; for i in 0 1 2; do count t-boot $i data; done      # marker + 300 on all three
```
Only `fullDBRepository` is needed (`manifestRepository` is optional and unusable, BUG 15). **If the backed-up cluster had RBAC on**, the snapshot carries
*its* root password, so the new Etcd must reference the same credentials (`authSecret: {name: t-user-auth, kind: Secret, externallyManaged: true}`) — a freshly
generated password could never authenticate. This path needs the **provisioner** rebuilt with the same `pkg/controller` fixes (it shares
`EnsureSnapshotRestoreSession`).

---

## 5. Resilience and failure handling

### R1 — leader killed under load   **PASS**
```bash
: > /tmp/acked; ( for i in $(seq 1 150); do ec t-general 1 put wl/$i v$i >/dev/null 2>&1 && echo $i >> /tmp/acked; done ) &
sleep 8; kubectl delete pod -n demo $(leader_pod t-general) --grace-period=0 --force
wait; sleep 20; wait_phase t-general Ready 200
LOST=0; for i in $(cat /tmp/acked); do [ "$(ec t-general 0 get wl/$i --print-value-only)" = "v$i" ] || LOST=$((LOST+1)); done; echo "acked=$(wc -l </tmp/acked) LOST=$LOST"
```
PASS: 150/150 acknowledged, **0 lost**, 0 failed, new leader elected, old leader rejoined as a follower with its data.

### R2 — member pod lost, disk kept   **PASS**
`kubectl delete pod -n demo <non-leader> --grace-period=0 --force`: phase `Ready → Critical` (~10s) `→ Ready` (~20s); writes keep succeeding on 2/3
members; the recovered member has all keys. (Contrast R3.)

### R3 — member loses its DISK while the leader stays up   **FAIL — BUG 13**
```bash
std_etcd t-loss 3; wait_phase t-loss Ready 240; load t-loss 0 l 40
V=t-loss-2; kubectl delete pvc -n demo data-$V --wait=false; kubectl delete pod -n demo $V        # a non-leader
# OBSERVED: pod CrashLoopBackOff forever; DB Critical:  tocommit(50) is out of range [lastIndex(0)]. Was the raft log corrupted, truncated, or lost?
```
The leader still tracks this member's match index, so an empty member panics on its first heartbeat. etcd requires *remove member → add fresh*; the operator has
no such replacement logic. This is the most common real-world failure (a node/disk dies). **Workaround (only the HIGHEST ordinal):**
```bash
ops down HorizontalScaling t-loss "  apply: Always
  horizontalScaling: {replicas: 2}
  timeout: 10m"; wait_ops down 400
ops up HorizontalScaling t-loss "  apply: Always
  horizontalScaling: {replicas: 3}
  timeout: 10m"; wait_ops up 400          # replaced member has all 40 keys
```
Note (P-F2): if **two** members are wiped *at once* and their pods come straight back, etcd elects a new leader and the blank members resync — no
intervention needed — so a naive "delete two pods" test does **not** reproduce quorum loss.

### R4 — provisioner killed mid scale-up   **PASS**
```bash
ops f1 HorizontalScaling t-custom "  horizontalScaling: {replicas: 5}
  timeout: 15m" >/dev/null
until [ "$(members t-custom | wc -l)" -ge 4 ]; do sleep 1; done          # a learner is now mid-add
kubectl delete pod -n kubedb kubedb-kubedb-provisioner-0 --grace-period=0 --force
wait_ops f1 420; wait_phase t-custom Ready 200; preflight t-custom 5
```
PASS: converged to 5 voters, canary on the newest member.

### R5 — etcd-ops killed mid rolling Restart   **PASS**
```bash
ops f2 Restart t-custom "  timeout: 15m" >/dev/null
until [ "$(ops_conditions f2 | grep -c 'EvictPod.*=True')" -ge 2 ]; do sleep 1; done
kubectl delete pod -n kubedb -l app.kubernetes.io/name=kubedb-etcd-ops --grace-period=0 --force
wait_ops f2 500; kubectl get etcd -n demo t-custom -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}'   # empty
```
PASS: resumed from the persisted conditions, 5 evictions total, no leaked pause.

### R6 — one op per database at a time   **PASS**
Two `Restart` ops created back to back: `a=Progressing`, `b=Pending`; `b` starts ~12s after `a` finishes; both `Successful`.

### R7 — `apply: IfReady` gate   **PASS**
```bash
std_etcd t-gate 1; wait_phase t-gate Ready 200
kubectl patch etcd -n demo t-gate --type=merge -p '{"spec":{"halted":true,"deletionPolicy":"Halt"}}'; wait_phase t-gate Halted 120
ops gate-op Restart t-gate "  timeout: 5m"; sleep 40; kubectl get etcdopsrequest -n demo gate-op -o jsonpath='{.status.phase}'   # Pending
kubectl patch etcd -n demo t-gate --type=merge -p '{"spec":{"halted":false}}'; wait_ops gate-op 400                              # runs by itself
```

### R8 — invalid requests   **PASS** (the ops *engine* rejects them; the admission webhook is unserved, BUG 10)
| Request | Result |
|---|---|
| `horizontalScaling.replicas: 0` | `Failed` — `must be at least 1` |
| `UpdateVersion` to `9.9.9` | `Failed` — `EtcdVersion 9.9.9 not found` |
| `VerticalScaling` with no resources | `Failed` — `spec.verticalScaling is empty` |
| `Restore` with no `fullDBRepository` | rejected at create by the CRD schema |
| any op for a **nonexistent** DB | stays `Pending` forever, no condition/message (F7) |

The DB is untouched in every case (`Ready`, not paused).

### R9 — deleting an in-flight ops request   **FAIL — BUG 19**
Delete an `EtcdOpsRequest` while it is `Progressing` (`kubectl delete etcdopsrequest -n demo <name>`). The engine logs only `EtcdOpsRequest does not exist anymore`;
`DatabasePaused=True` (message `EtcdOpsRequest <name> is in process`) stays **forever**, the DB sits `Critical`, and every later `apply: IfReady` op stays `Pending`.
Found by accident: the autoscaler created an op which paused the DB; deleting it 5s later froze the DB for 10+ minutes. **Workaround:** `clear_pause <db>`.
The BUG 8 heal only covers requests that still exist in a terminal phase.

---

## 6. Extras

### X1 — EtcdAutoscaler (compute)   **PASS** (with metrics-server)
```bash
curl -sL https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml \
  | sed 's|- --metric-resolution=15s|- --metric-resolution=15s\n        - --kubelet-insecure-tls|' | kubectl apply -f -     # k3s needs the flag
kubectl apply -f - <<'EOF'
apiVersion: autoscaling.kubedb.com/v1alpha1
kind: EtcdAutoscaler
metadata: {name: t-scaler, namespace: demo}
spec:
  databaseRef: {name: t-custom}
  opsRequestOptions: {apply: IfReady, timeout: 5m}
  compute:
    etcd:
      trigger: "On"
      podLifeTimeThreshold: 1m
      resourceDiffPercentage: 5
      minAllowed: {cpu: 200m, memory: 256Mi}
      maxAllowed: {cpu: 2, memory: 4Gi}
      controlledResources: ["cpu", "memory"]
      containerControlledValues: "RequestsAndLimits"
EOF
kubectl get etcdautoscaler -n demo t-scaler -o jsonpath='{.status.vpas[0].conditions}'        # RecommendationProvided=True once metrics flow (~5 min)
kubectl get etcdopsrequest -n demo | grep '^etcdops-t-custom'                                  # autoscaler names its ops etcdops-<db>-<rand>
```
Without metrics-server the controller reconciles and checkpoints but reports `RecommendationProvided=False` (no ops). With it, the recommendation
(200m / 256Mi vs current 500m / 1Gi) **created a `VerticalScaling` op itself**, which ran to `Successful` with the pods carrying the recommended resources.
Caveat: it created **3 ops in ~5 minutes for the same target** (each re-rolling all members) — churn rather than one convergent change — and it set a
`512Mi` memory limit on the etcd container, which is tight for a large backend. **Delete the autoscaler CR before running other ops** (it competes for the same DB).
Not tested: storage autoscaler (needs volume-usage metrics + an expandable class).

### X2 — GitOps   **NOT TESTED** — needs the `kubedb-gitops` operator and a Git repository.

---

## 7. Findings that are not blockers

| ID | Finding |
|---|---|
| F1 | `removeCustomConfig` does not unset tuning knobs; no ops-based unset (workaround in O8) |
| F2 | Wiping several members whose pods return within seconds self-heals (blank members resync after a new election) — not a way to test quorum loss |
| F3 | Removing `spec.monitor` leaves the `<db>-stats` Service behind |
| F4 | The AppBinding keeps a stale `caBundle` after `ReconfigureTLS remove` |
| F5 | Detaching `spec.archiver` (and the label) does not delete the archiver's BackupConfiguration |
| F7 | An op referencing a nonexistent DB stays `Pending` forever without a message |
| F8 | TLS removal leaves the `<db>-{server,peer,client}-cert` Secrets behind |

## 8. Stale documentation found (`docs/docs/guides/etcd/`, all 78 pages are marked unverified)

- Quickstart uses `storageClassName: "standard"`; several examples name the DB `etcd-cluster` while the quickstart creates `etcd-quickstart`.
- `backup/kubestash/overview/index.md` says the restore task is `etcd-backup-restore`; the shipped addon (and, after the fix, the operator) uses **`etcd-restore`**.
- The KubeStash guide presents the archiver flow as working; it fails today (BUGs 14, 15).
- Reconfigure guide does not say that tuning knobs cannot be unset; `deletionPolicy: DoNotTerminate` and `halted: true` behaviour depends on the unserved webhook.

## 9. Cleanup

```bash
kubectl delete etcdautoscaler,etcdopsrequest,backupconfiguration,backupsession,restoresession,snapshot -n demo --all
for db in $(kubectl get etcd -n demo -o name | grep '/t-'); do kubectl delete -n demo $db; done   # all WipeOut
left t-general; left t-custom          # should print nothing; delete leftover PVCs/Secrets from Halt/Delete/DoNotTerminate runs by hand
# infra you may keep between runs: cert issuers, s3 ns, monitoring ns + Prometheus, metrics-server, StorageClass local-path-2, image-importer pod
```
