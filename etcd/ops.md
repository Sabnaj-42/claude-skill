# EtcdOpsRequest engine and the 14 types

Everything here runs in the **etcd-ops** binary (`workflows.md` for how to deploy it).
A change under `pkg/ops` = rebuild etcd-ops; under `pkg/controller` = rebuild provisioner.

## Engine mechanics (`pkg/ops`)

- `ops_request.go › Reconcile`: terminal phases are a hard no-op **plus the pause-heal**
  (`resumeIfNoActiveSibling` — a stale-cache re-run after `finish()` can re-pause the DB;
  the heal removes a leaked `DatabasePaused` when no sibling request is active).
  Then Pending, skipper (one Progressing per DB; same-type Pendings collapse to newest),
  `apply: IfReady` gate (needs phase Ready; `Always` needs only DatabaseProvisioned),
  backup interlock, dispatch.
- `step.go › runStep(cond, msg, typ, fn)`: fn returns `(retryable, err)`. Timeouts have no
  counter: `stepWaiter.Wait` stamps the condition False once and compares its PERSISTED
  `LastTransitionTime` against `spec.timeout` (default budget 10m) — deleting/re-creating a
  request is the only way to reset a burned budget. Conditions are `<Step>` or
  `<Step>--<resource>`; a completed step can carry a value in its message
  (`conditionDetail`/`conditionSuffix`).
- **Umbrella-vs-inner condition rule (BUG 5 class): a `runStep` umbrella condition must never
  share a type with an inner `stepWaiter`** — `Initialize()` marks the inner one True and the
  next pass skips the whole step. Precedent: `etcdMembershipConverged` in
  `horizontal_scaling.go`.
- Pause: `waitingForPause` → provisioner flips `DatabasePaused` Unknown→True and returns.
  `finish()` resumes; `markSuccessful()` doesn't (for the never-pause types:
  HorizontalScaling, MoveLeader, Defragment, Compact).
- `restart.go › restartPodsFunc`: followers first, leader last (leadership transferred, not
  evicted-into-election). During a TLS roll it carries `altDB` (the folded desired state) and
  every leader/quorum interaction is **dual-view with per-view timeout budgets**
  (`checkQuorumWith`, `getLeaderDualView`, `moveLeadershipAwayFromWith`) plus
  **`syncPeerURL`** — the etcd-documented MemberUpdate step (BUG 9 root cause).
- Pod-surgery (`podsurgery.go`): orphan PetSet → stash pod manifest in an ANNOTATION before
  delete → PVC identity-relocation/discard with PVs parked at Retain → restore. Used by
  StorageMigration / RecoverFromQuorumLoss / Restore.

## The 14 types — live status (2026-09-25 full run; commands + expected output: `testing/README.md`)

| Type | Live status | Notes / traps |
|---|---|---|
| Restart | ✅ 50–65s | followers first, leader last (MoveLeader then evict); reused verbatim by UpdateVersion/VerticalScaling/Reconfigure/ReconfigureTLS |
| MoveLeader | ✅ 5s | auto and `newLeader`; etcd-only; no pause; auto-pick skips learners |
| HorizontalScaling | ✅ | 3→5→3→1→3 with data, RBAC on, and with the provisioner killed mid-scale. Scale-down removes the highest ordinal from etcd, shrinks the PetSet, **deletes that PVC**; scale-up defensively deletes a stale PVC (else "rejected Raft message to mismatch member"). Doubles as the **only workaround for a dead highest-ordinal member** (BUG 13) |
| VerticalScaling | ✅ both modes | `Restart`: new pod UIDs, 50s. `InPlace`: pods/resize, same UID, restartCount 0, 10s. Fetch-the-PetSet rule (BUG 7) |
| UpdateVersion | ✅ 50s | 3.5.21→3.6.4 with data; **downgrade refused** (`Failed`, DB untouched) |
| Reconfigure | ✅ 50s, limitation | tuning knobs are flags → always a roll. `removeCustomConfig` does **not** unset knobs (F1); workaround = patch the Etcd spec then `Restart` |
| ReconfigureTLS | ✅ add 91s / rotate 55s / update subject 61s / remove 81s | on an RBAC-enabled cluster with data. Dual-view gates + `syncPeerURL` (BUG 9). Cert Secrets remain after remove |
| RotateAuth | ✅ 5s | first rotation **enables RBAC**; generated and user-supplied (`externallyManaged`) both verified; scale/restart still work afterwards |
| Compact | ✅ 5s | default and explicit `revision`; old revision unreadable on every member |
| Defragment | ✅ 5s | file 2.7 MB → 48 KB on every member; leader last, per-member quorum gate, alarm cleared |
| StorageMigration | ✅ 167s | needs a second StorageClass (a second `local-path` class works); Raft state survives the PVC copy |
| VolumeExpansion | ⛔ env | on `local-path` the op patches PVC requests, waits, and **Fails cleanly** at the timeout leaving the DB Ready/unpaused. Needs a resizable CSI to pass |
| RecoverFromQuorumLoss | ❌ BUG 11 | admitted only if `QuorumLost=True`, which is never raised; with it hand-stamped the op stalls at survivor resolution. Rest of the procedure UNTESTED |
| Restore | ✅ after BUGs 16/17/18 | in-place from a KubeStash Repository, 51s; **verify by reading data back** (BUG 18 = silent empty DB). Needs etcd-ops RBAC for `restoresessions` |

## ReconfigureTLS — read before touching

The roll flips each member's client AND peer scheme while `spec.tls` persists only at the
end. Everything the engine does mid-roll must therefore work from BOTH views:

1. Quorum gate, leader resolution, leadership move: dual-view (old || desired), each attempt
   with its OWN timeout (a dead endpoint eats a whole context — also why db-client-go
   `Status` bounds each probe).
2. **`syncPeerURL` right after each member's eviction** + catch-up sync at the top of every
   pass: Raft dials by REGISTERED peer URLs; without MemberUpdate the flipped members stay
   registered `http://` and the cluster eventually partitions completely (all-members-flipped
   + all-http-registry = no leader, election storm).
3. Odd cluster sizes: one homogeneous view always sees the majority. An even split failing
   both views is a REAL quorum loss — do not "fix" that.
4. Cert sync waits are per-certificate and skip `metrics-exporter`.

Recovery from a TLS-partitioned cluster: clear any leaked Paused condition, let the
provisioner re-render the plaintext template, delete ALL pods together — then remember
`podManagementPolicy: OrderedReady` deadlocks multi-pod recreation (pod-0 can't be Ready
without quorum, pods 1+ never created). If wedged there: WipeOut, or scale games. Upstream
recommendation: render `Parallel` in `EnsurePetSet`.

## Debugging a stuck request

```bash
kubectl get etcdopsrequest -n <ns> <name> -o jsonpath='{range .status.conditions[*]}{.lastTransitionTime} {.type}={.status} {.message}{"\n"}{end}'
kubectl logs -n kubedb deploy/kubedb-etcd-ops --since=5m | grep -v retry_interceptor
kubectl get etcd -n <ns> <db> -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'   # look for a stuck Paused=True
```
Conditions are the state machine: absent = not started, False = in flight (its
LastTransitionTime is the step's timeout clock), True = done. A request that sat in an
unreachable engine burns its budgets — delete and re-create rather than puzzling over
inherited False timestamps.
