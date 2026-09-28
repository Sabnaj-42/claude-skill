# Build → deploy → test loop (live-verified 2026-09-03, k3s-80)

## 0. Cluster prerequisites

- KubeDB chart ≥ v2026.8.26-rc.2 with `--set global.featureGates.Etcd=true`
  (crd-manager installs the 6 CRDs; catalog creates EtcdVersions 3.5.21 + 3.6.4).
- **cert-manager**: the kubedb chart ships only certificates+issuers CRDs; `kubectl apply`
  the full upstream `cert-manager.crds.yaml`, then
  `helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=false`
  (direct install fails on CRD ownership). **etcd-ops crashes at startup without these CRDs.**
- **etcd-ops Deployment** — no chart ships one. Use `assets/etcd-ops-deploy.yaml`
  (SA `kubedb-kubedb-ops-manager`, license secret `kubedb-kubedb-ops-manager-license`
  mounted, args `operator --license-file=...`). Running the binary on a workstation does NOT
  work for day-2 ops: it reconciles but cannot resolve `*.svc.cluster.local` member DNS.

## 1. Worktrees & code

```bash
git -C ~/go/src/kubedb.dev/etcd worktree add -b <task> ~/go/src/kubedb.dev/etcd.worktrees/<task> fix-psclient-provisioner-host
export GOCACHE=/tmp/gocache-etcd            # per-agent cache; parallel builds thrash a shared one
go build -mod=vendor ./...                  # fast compile check (LSP vendor-path noise is ignorable)
```

## 2. Build images

Provisioner (hosts `pkg/controller` + db-client-go changes) — HAND-SPLICE into vendor:
```bash
P=~/go/src/kubedb.dev/provisioner.worktrees/etcd-dev        # branch etcddev — the SHARED dev worktree/tag.
# Working in parallel with other agents? Make your own provisioner worktree+branch; the branch
# name becomes the image tag (VERSION=branch), so adjust the make target and helm tag to match.
cp <etcd-worktree>/pkg/controller/<changed>.go  $P/vendor/kubedb.dev/etcd/pkg/controller/
cp <etcd-worktree>/vendor/kubedb.dev/db-client-go/etcd/*.go $P/vendor/kubedb.dev/db-client-go/etcd/   # if touched
cd $P && GOCACHE=/tmp/gocache-provisioner go build -mod=vendor ./pkg/... \
  && rm -f bin/.container-* \
  && make bin/.container-ghcr.io_kubedb_kubedb-provisioner-etcddev_linux_amd64-PROD
```

etcd-ops (hosts `pkg/ops` + `pkg/cmds`) — built in the etcd worktree itself:
```bash
cd <etcd-worktree> && rm -f bin/.container-* bin/linux_amd64/etcd-ops
make BIN=etcd-ops bin/.container-ghcr.io_kubedb_etcd-ops-<branch>_linux_amd64-PROD
docker run --rm ghcr.io/kubedb/etcd-ops:<branch>_linux_amd64 version | grep CommitHash   # MUST equal git rev-parse HEAD
```
That CommitHash check is the strings-marker rule: never deploy without proving the image
carries your commit (stale-stamp make targets have burned this loop before).

The PROVISIONER image's own CommitHash is the provisioner repo's, not your etcd commit — the
splice is invisible to it. Prove a splice landed by symbol instead:
```bash
docker create --name p-inspect ghcr.io/kubedb/kubedb-provisioner:etcddev_linux_amd64 \
  && docker cp p-inspect:/kubedb-provisioner /tmp/prov-bin && docker rm p-inspect
go tool nm /tmp/prov-bin | grep <aSymbolYouAdded>   # or strings for a new literal
```

## 3. Ship to the cluster (no registry push — side-load)

`kubectl exec` streams flake above ~100MB; serve over HTTP instead. First
`kubectl apply -f assets/image-importer.yaml` (privileged busybox with the host filesystem
at `/host`).

```bash
docker save ghcr.io/kubedb/<img>:<tag> -o /tmp/img.tar
(cd /tmp && python3 -m http.server 18475 --bind 0.0.0.0 &)      # kill by PID afterwards —
        # NEVER `pkill -f` a pattern that appears in your own command line (it kills your shell)
# <workstation-ip> = your address AS THE NODE SEES IT:
#   NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
#   WORKSTATION_IP=$(ip route get $NODE_IP | grep -oP 'src \K\S+')
kubectl exec -n kube-system image-importer -- sh -c \
  "wget -q -O /host/tmp/img.tar http://<workstation-ip>:18475/img.tar \
   && chroot /host /usr/local/bin/k3s ctr -n k8s.io images rm ghcr.io/kubedb/<img>:<tag> 2>/dev/null; \
   chroot /host /usr/local/bin/k3s ctr -n k8s.io images import /tmp/img.tar && rm /host/tmp/img.tar"
```
Delete-then-import: a plain re-import over an existing ref can leave CRI serving the old
image. Verify with `crictl images | grep <img>` if in doubt — but the CommitHash check on a
fresh pod is the real proof.

## 4. Activate

- Provisioner: tag once via `helm upgrade kubedb appscode/kubedb -n kubedb --reuse-values
  --set kubedb-provisioner.operator.tag=etcddev_linux_amd64`, then every iteration is just
  `kubectl delete pod -n kubedb kubedb-kubedb-provisioner-0` (PetSet, OnDelete).
- etcd-ops: `kubectl rollout restart deploy/kubedb-etcd-ops -n kubedb` — and confirm the NEW
  pod's imageID/behavior; a rollout against a not-yet-imported image silently keeps the old one.

## 5. Verify (preflight gate — mandatory before any test claims)

```bash
kubectl apply -f - <<'EOF'
apiVersion: kubedb.com/v1alpha2
kind: Etcd
metadata: {name: etcd-t, namespace: demo}
spec: {version: "3.6.4", replicas: 3, storageType: Durable, deletionPolicy: WipeOut,
  storage: {storageClassName: local-path, accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}}
EOF
# expect: 1 pod -> 3 pods over ~60s (learner-add/promote), phase Ready
kubectl exec -n demo etcd-t-0 -- etcdctl member list          # 3 voters, no learner
kubectl exec -n demo etcd-t-0 -- etcdctl put k v && kubectl exec -n demo etcd-t-2 -- etcdctl get k
```
No shell in the DB image — exec `etcdctl` directly. With TLS:
`--endpoints=https://localhost:2379 --cacert=/var/run/etcd/tls/client/ca.crt --cert=.../tls.crt --key=.../tls.key`;
with RBAC on add `--user root:$(kubectl get secret -n demo <db>-auth -o jsonpath='{.data.password}' | base64 -d)`
(the client cert CN=root also authenticates by itself).

Then run the relevant ops from `ops.md` and read conditions, not just phase.

## 6. Testing

The full runnable feature test plan (provisioning, 14 ops, backup/restore, resilience, autoscaler) with exact commands, pass criteria and real results is
`testing/README.md`; its helper library is `testing/lib.sh` (`source` it: `ec`, `preflight`, `load`, `count`, `ops`, `wait_ops`, `leader_pod`, `clear_pause`, ...)
and its manifests are in `etcd/testing/manifests/`. Build-time notes learned while running it:

- If `ghcr.io/appscode/golang-dev:<ver>` is "denied", the Makefile's `GO_VERSION` (1.25.5) is not pullable — override with `make GO_VERSION=1.25 ...` (the cached `golang-dev:1.25` works).
- `etcd-ops` needs KubeStash RBAC for the Restore op: `kubectl apply -f assets/etcd-ops-kubestash-rbac.yaml`.
- The backup/restore plugin image is not pullable: build `etcd-restic-plugin` (`make container-3.6.4_linux_amd64`), tag it `ghcr.io/kubedb/etcd-restic-plugin:v0.1.0-rc.2_3.6.4`, side-load it.
- The provisioner is a **StatefulSet** (`kubectl scale statefulset kubedb-kubedb-provisioner -n kubedb`), while the etcd database workload is a **PetSet**.
- A shell command that exceeds ~10 minutes is moved to the background; long ops belong in a script you poll, not one blocking call.

## Known cluster/test-env limits

Single-node k3s + `local-path` SC: no VolumeExpansion (AllowVolumeExpansion=false), no
StorageMigration (one SC), no backup/Restore (no object store — install minio first).
`~/k3s-80.yaml` is the etcd cluster; `~/k3s-35.yaml` belongs to the milvus effort.
