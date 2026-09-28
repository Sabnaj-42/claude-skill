# Bug ledger — 19 live-found bugs + landmines

All reproduced on a real cluster 2026-09-02/03 against release v2026.8.26-rc.2. Each entry:
symptom → cause → fix commit. Before relying on a fix, check whether it has merged to master
(BASELINE.md drift check). Extended evidence (logs, timelines):
`$HOME/go/src/kubedb.dev/prompt-library.worktrees/etcd-knowledge/routine-tasks/etcd/FINDINGS.md`.

**Current status (2026-09-28 fix pass): only #12 and #13 remain open, both because they need a
design change rather than a targeted code fix (PetSet reseed/podManagementPolicy for #12; a
whole member-replacement subsystem that doesn't exist yet for #13). Every other bug in this
ledger is fixed and live-retested. Fix branches for this pass, all unpushed/no-PR:**
- `webhook-server.worktrees/fix-etcd-webhooks` branch `fix-etcd-webhooks` @ `a4f628d90` (bug 10)
- `installer.worktrees/etcd-dev` branch `fix-etcd-autoscaler-webhook-configs` @ `5c3a7c1b7` (bug 10, chart configs)
- `etcd.worktrees/fix-quorum-pause` branch `fix-quorum-detect-and-resume-pause` @ `811410b7`, stacked on `fix-backup-restore-task-name` (bugs 11, 19)
- `provisioner.worktrees/etcd-dev-b11` branch `etcddevb11`, uncommitted vendor splice of the health.go fix (bug 11 — provisioner-hosted half)
- `kubedb-manifest-plugin.worktrees/fix-etcd-support` branch `fix-etcd-support` @ `f8990fc8` (bug 15)

## Provisioning path (rebuild = provisioner image)

**1. PSClient nil panic — PetSet never created** (`8719c74e`)
Etcd stuck Provisioning, services+CM+auth-secret exist, no PetSet; provisioner logs panic in
`checkPetSet`. The provisioner's shared `amc.Controller` never sets PSClient. Fix: the two
typed reads (`checkPetSet`, `waitUntilPetSetsDeleted`) now go through `KBClient`.

**3. Credentialed learner dials — multi-member bootstrap deadlocks** (`6cc794d7`, revised by `52e5cb15`)
Bootstrap stalls at 2 members, member 1 `isLearner=true` forever; logs loop on
`Authenticate ... rpc not supported for learner`. The auth secret always carries a password,
so every dial authenticates; learners serve no Authenticate RPC. Fix:
`WithoutAuthentication()` for the learner status dial; and since etcd RBAC (once enabled)
rejects anonymous Status (`user name is empty`), `promoteLearnerIfReady` falls back to
attempting `MemberPromote` and letting etcd itself reject a not-in-sync learner.

**4. PSLister nil — no Etcd ever reached Ready** (`5fe8c1c0`)
Cluster healthy, membership settled, but conditions stop at ProvisioningStarted. Nothing
populates PSLister in ANY hosting shape → `updateReplicaReadyCondition` silently no-ops →
health checker never starts → AcceptingConnection/Ready/Provisioned never set. Fix: compute
readiness via `KBClient` List + `petsetutil.PetSetsAreReady`.

**6. Scale-down leaves the removed member's PVC — re-scale-up crash-loops** (`f7965cf4`)
Pod boots from the old volume; peers reject it (`rejected Raft message to mismatch member`).
Fix: `discardStaleMemberPVC` on scale-down (after PetSet shrink) and defensively before every
learner add. Manual recovery on pre-fix clusters:
`kubectl delete pvc data-<db>-<ord> --wait=false && kubectl delete pod <db>-<ord>`.

## Ops path (rebuild = etcd-ops image)

**2. cert-manager kinds not in the ops Scheme** (`b72fef8b`)
`no kind is registered for the type v1.Issuer` — TLS issuance dead. Fix: `cmapi.AddToScheme`
in `ops_operator.go › Run`. Flip side: with the kinds registered, **etcd-ops hard-crashes at
startup when cert-manager CRDs are absent** (cache-sync timeout) — install them first.

**5. HorizontalScaling Successful mid-scale** (`05d355b3`)
Declared success with an unstarted learner. The umbrella `runStep` condition shared its type
with the inner member-count waiter, whose `Initialize()` short-circuited the whole step. Fix:
dedicated `etcdMembershipConverged`. **Rule: umbrella and inner stepWaiter types must differ.**

**7. Stub `clientutil.Patch` = silent no-op** (`90d14d03`)
VerticalScaling/UpdateVersion "Successful" with pods still on the old template.
`clientutil.Patch` diffs the passed object vs its transform WITHOUT reading it; an
ObjectMeta-only stub has zero containers to rewrite. Fix: fetch via `c.petSet()` first.
**Rule: never hand clientutil.Patch an unfetched object.**

**8. Stale-cache re-run leaks DatabasePaused forever** (`9729ac4e`)
4ms after `finish()`, the next Reconcile read a cache without Successful, re-ran the handler,
re-paused — then terminal no-ops forever; DB frozen Critical, provisioner locked out. Fix:
terminal branch runs `resumeIfNoActiveSibling`.

**9. ReconfigureTLS wedges/partitions the cluster** (`e8618ca5`→`c91fd76e`, five sub-bugs)
(a) quorum gate dialed only the old scheme (spec.tls persists post-roll) → dual-view gate;
(b) the old-view attempt burned the shared context → per-view timeout budgets;
(c) db-client-go `Status` fanned out unbounded per endpoint → per-probe `HealthCheckTimeout`;
(d) GetLeader + MoveLeader were single-view → dual-view;
(e) **root cause: no `MemberUpdate`** — Raft dials by REGISTERED peer URLs, which stayed
`http://` while listeners flipped to TLS → full mutual rejection, cluster-wide partition,
election storm. Fix: `syncPeerURL` after each member's eviction + catch-up sync each pass
(etcd's own documented TLS-migration step). Clean add-TLS verified in 100s. Resuming a
half-rolled cluster from a PRE-fix engine remains fragile — recovery recipe in `ops.md`.

**10. Admission webhooks are not served** [webhook-server + installer] — FIXED (`webhook-server` `a4f628d90`, `installer` `5c3a7c1b7`)
Root cause was worse than "3 lines missing": webhook-server's vendored apimachinery snapshot
predated etcd entirely, so it had zero Etcd/EtcdAutoscaler types or webhook packages vendored —
nothing could have been registered. Fix: hand-spliced the Etcd/EtcdAutoscaler/EtcdVersion type
chain + the two webhook setup files into vendor, registered `SetupEtcdWebhookWithManager` and
`SetupEtcdAutoscalerWebhookWithManager` in `setup.go` (deliberately NOT `SetupEtcdOpsRequestWebhookWithManager`
— ops-manager's `start.go` already does that; double-registering was the trap). installer chart
was missing EtcdAutoscaler's validating+mutating webhook entries entirely (Etcd's 2 existed with
`failurePolicy: Ignore`, silently swallowing the 404s) — added both. Verified live: an invalid
Etcd (bad version, `replicas: 0`) is now rejected at admission; a valid Etcd still provisions;
an EtcdAutoscaler missing `databaseRef` is rejected and a valid one gets observably defaulted
by the mutating webhook.

## Found by the 2026-09-25 full feature test (BUG 11–19)

Reproduced live with `testing/README.md` (test IDs in brackets). **Fixed + verified (2026-09-28
pass):** 11, 14, 16, 17, 18, 19. **Open — need a design change, not a code fix:** 12, 13. Branches
carrying the fixes are listed in `BASELINE.md`.

**11. Quorum loss is invisible, and RecoverFromQuorumLoss cannot start** [O13] — FIXED (`etcd` `811410b7`, provisioner vendor splice `etcddevb11`)
Symptom: after a permanent majority loss the DB went `NotReady`/`AcceptingConnection=False` but `QuorumLost` was never raised; `RecoverFromQuorumLoss` never resolved
a survivor. Cause: THREE separate call sites built a **credentialed** client — `health.go`'s health check, `recover_from_quorum_loss.go`'s survivor picker, AND its
`quorumLossPreflight` — and `clientv3.New`'s `Authenticate` RPC needs a Raft leader to complete, so with no leader every one of them times out before any quorum
logic runs. Proof: `etcdctl --user root:… endpoint status` hangs ~3s; **without** `--user` it answers in 0.15s with `errors=['etcdserver: no leader']`. Fix: fall
back to etcd's always-unauthenticated plain-http metrics endpoint (`:2381/metrics`) — `etcd_server_has_leader` for detection, `etcd_server_proposals_applied_total`
for survivor selection — and made the preflight read the health checker's own `QuorumLost` condition off the API server instead of re-dialing. Verified live: killing
a majority now flips `QuorumLost=True` (`etcd_server_has_leader=0`), and `RecoverFromQuorumLoss` with a `confirmMember` reaches `Successful` and the condition flips
back `False`.

**12. Halt/resume of a multi-member cluster deadlocks** [P6] — OPEN
`halted:true` (+ `deletionPolicy: Halt`) removes pods/PetSet/Services/PDB and keeps PVCs. `halted:false` re-creates the PetSet with the **1-replica bootstrap seed**
(`EnsurePetSet` seeds 1 only on creation), but pod-0's retained data dir remembers a 3-member Raft config → it loops elections with 1/3 votes, and the provisioner
cannot grow the PetSet (its client hangs — same mechanism as 11). Same for recreating a CR over retained PVCs. Single-member works. Direction: seed the PetSet with
the number of retained data PVCs (min 1) instead of always 1.

**13. A member that loses its data never rejoins** [P3, R3] — OPEN
An empty member with the same identity panics on its first heartbeat: `tocommit(N) is out of range [lastIndex(0)]. Was the raft log corrupted, truncated, or lost?`
(the leader still tracks its match index). Hits Ephemeral storage on *any* pod recreation (eviction, drain, the operator's own Restart) and Durable storage when a PVC is
lost while the leader is up — the most common real-world failure. etcd requires remove-member-then-add-fresh; the operator has no replacement logic. Workaround for the
highest ordinal only: `HorizontalScaling` N→N-1 then back (`apply: Always`). Note: wiping **several** members whose pods return within seconds self-heals (a new election resets
the leader's tracking), so a naive two-pod delete does not reproduce it.

**14. Backup fails at the first dial** [B2] — FIXED (`etcd-restic-plugin` `0d92022`)
The operator publishes `AppBinding.spec.clientConfig.service.scheme = "etcd"` (db-type convention), so `AppBinding.URL()` is `etcd://host:2379/`; the plugin handed that to
clientv3 → `dial tcp: address etcd://host:2379/: too many colons in address`. Fix: `normalizeEndpoint` keeps host:port and picks http/https from the **Etcd object's** TLS
state (not the AppBinding `caBundle`, which survives TLS removal).

**15. The manifest plugin rejects Etcd, failing every archiver backup** [B2] — FIXED (`kubedb-manifest-plugin` `f8990fc8`)
The archiver's `full-backup` session also runs the shared `manifest-backup` task; the KubeDB manifest plugin answered `error: Etcd is not supported`, so the
Snapshot/BackupSession was `Failed` even though the etcd data component `Succeeded`. Fix: added `dumpEtcdManifests`/`createEtcdManifests` mirroring the existing
ZooKeeper handling (CR + AuthSecret + config Secret — same shape), wired the `Etcd` case into the dump/restore switches, and hand-spliced an `Etcd` field into the
vendored `kubestash.dev/apimachinery` `ManifestRestoreOptions` struct (still has no upstream member — needs a `kubestash.dev/apimachinery` PR + vendor bump to land
cleanly, noted in the commit). Verified live: Snapshot's manifest component now `Succeeded` alongside the data component, on a real `EtcdArchiver`/`BackupConfiguration`.

**16. Restore asks for a task that does not exist** [B3] — FIXED (etcd `3a07bd4c`)
`defaultEtcdFullRestoreTaskName = "etcd-backup-restore"` but the installer's `etcd-addon` ships `etcd-restore` → RestoreSession `Invalid` (`Task etcd-backup-restore of Addon etcd-addon does not exist`).
The in-place Restore op only finds out **after** it has discarded members and wiped the seed volume, leaving the cluster down. Docs still say `etcd-backup-restore`.

**17. The plugin cannot find the Etcd from a restore target** [B3] — FIXED (`etcd-restic-plugin` `00390f2`)
`GetEtcd` used the RestoreSession target name as the database name, but the operator targets the seed **PVC** (`data-<db>-0`) → `etcds.kubedb.com "data-<db>-0" not found`; no member
name / peer URLs; and the plugin's `main` logs errors and **exits 0**, so the Job showed `Completed` while restoring nothing. Fix: resolve the Etcd through the PVC's Etcd ownerRef / instance label.

**18. A "successful" restore yields an EMPTY database — CRITICAL silent data loss** [B3] — FIXED (etcd `ce1942d5`)
The plugin rebuilds `member/` at `<dataDir>/member` with `dataDir` defaulting to the mount root `/var/lib/etcd`, but the operator runs etcd with `--data-dir=/var/lib/etcd/data`. etcd never sees the
restored data, bootstraps a brand-new cluster in `data/`, and the op finishes `Successful` with the cluster `Ready` — and empty. Proof: mount the PVC in a busybox pod: `/v/member` (62 MB restored)
sits beside `/v/data/member` (fresh). Fix: pass `dataDir = etcdDataDir()` as a task param on the snapshot RestoreSession (covers the in-place op and `init.archiver`, which share `EnsureSnapshotRestoreSession`).
**Rule: verify a restore by reading the data back, never by the op's status.**

**19. Deleting an in-flight ops request freezes the database** [R9] — FIXED (`etcd` `f445d36f`)
`kubectl delete etcdopsrequest` while `Progressing` used to leave `DatabasePaused=True` (message `EtcdOpsRequest <name> is in process`) forever; the engine only
logged `does not exist anymore`. The BUG 8 heal only covered requests that still existed in a terminal phase. Fix: in the NotFound branch of ops `Reconcile`, resume
any Etcd in the request's namespace whose `DatabasePaused` message names the deleted request, when no other active sibling op exists for it — same
`resumeIfNoActiveSibling` logic, driven from a db scan instead of the (now-gone) request object. Verified live: log shows `EtcdOpsRequest does not exist anymore` →
`Removing a DatabasePaused condition leaked by a finished ops request`; DB returns to Ready with no manual `clear_pause` needed.

**Minor findings** (details in `etcd/testing/README.md` §7): `removeCustomConfig` cannot unset tuning knobs (F1); removing `spec.monitor` leaves `<db>-stats` behind (F3); AppBinding keeps a stale
`caBundle` after TLS removal (F4); detaching the archiver leaves its BackupConfiguration (F5); an op for a nonexistent DB stays Pending silently (F7); TLS removal leaves the cert Secrets (F8);
the autoscaler created 3 VerticalScaling ops in ~5 min for one target and sets a `512Mi` memory limit on etcd. **`etcd-ops` needs its own RBAC**: reusing the ops-manager ServiceAccount, the Restore op
stalls at `restoresessions.core.kubestash.com is forbidden` (`assets/etcd-ops-kubestash-rbac.yaml`) — one more reason a proper etcd-ops chart is needed. **The `ghcr.io/kubedb/etcd-restic-plugin:v0.1.0-rc.2_<ver>`
image is not pullable** — build and side-load it; MinIO's community images are no longer pullable either (use `etcd/testing/manifests/s3-server.yaml`).

## Landmines (not bugs in one line of code)

- **OrderedReady PetSet + quorum-gated readiness = recreation deadlock** when several pods
  are gone at once (pod-0 can't turn Ready without quorum; pods 1+ never get created).
  Recommend rendering `Parallel` in `EnsurePetSet` upstream; field is immutable on existing
  PetSets.
- **Learners ARE Ready on etcd 3.6.4** (metrics-listener /health passes) — DESIGN.md's
  "client Service routes only voters" assumption is false; cluster-client RPCs are per-pass
  flaky while a learner exists. Hardening candidate: voting-member endpoints for the cluster
  client.
- **Status is NOT anonymous under RBAC** (DESIGN.md §6 is wrong): `user name is empty`.
  Voters must be probed with credentials (clientv3 swallows ErrAuthNotEnabled when RBAC off).
- Vendored db-client-go changes (bugs 3, 9c) need an **upstream kubedb.dev/db-client-go PR +
  vendor bump** before the etcd repo branch can merge cleanly.
- `update_version.go` stamps the catalog's EMPTY `InitContainer.Image` onto any user init
  container named `etcd-init`.
