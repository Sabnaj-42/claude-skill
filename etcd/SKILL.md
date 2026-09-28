---
name: kubedb-etcd-testing
description: >-
  Run or extend the KubeDB-managed etcd test suite — provisioning, all 14 EtcdOpsRequest
  types, backup/restore via KubeStash, resilience/chaos scenarios, and regression after any
  code change. Use for any task that verifies etcd behavior on a live cluster rather than
  writes new operator code: "test etcd", "does <op> work", "reproduce bug <N>", "regression
  test after this fix", "is etcd ready to ship".
allowed-tools: [Bash, Read, Edit, Write, Grep, Glob, Agent]
disable-model-invocation: true
---

# KubeDB etcd — testing

Router for **verifying** etcd on a live cluster. For writing operator/plugin code, use the
sibling `kubedb-etcd-dev` skill instead — this one assumes the code is already built/deployed
and you're proving behavior. Read `BASELINE.md` first (it pins which commit every claim below
was checked against — etcd moves, so re-derive anything that looks stale), then the one file
your task maps to.

## Non-negotiables

1. **Preflight gate before any test claim.** Phase `Ready` alone is not evidence. Confirm
   `etcdctl endpoint health` on every member + a cross-member write/read + equal revisions —
   `preflight` in `testing/lib.sh` does this. **Verify a restore by reading the data back**,
   never by the op's reported status (a past bug shipped `Successful` on an empty database).
2. **Ask the user which kubeconfig/cluster** before touching anything — a shared rig may be
   running other people's or other agents' work. Never assume `~/k3s-80.yaml` still exists or
   is idle; confirm.
3. **Know which bugs are still open before you file a new one.** `bugs.md` is the ledger,
   symptom-indexed near the top of each entry. If you hit a symptom that matches an open bug,
   link to it instead of re-discovering it; if it matches a bug marked fixed, that's a
   regression — say so explicitly.
4. **Test on disposable CRs, never on a long-lived one.** Give test resources unique names
   (e.g. `etcd-<area>-test`) in namespace `demo` and delete them when done. Destructive ops
   (`RecoverFromQuorumLoss`, `Restore`, anything with `WipeOut`) only ever run against a
   throwaway CR you created for that test.
5. **The build matters.** Release images (`v0.1.0-rc.2`/whatever master currently is) may not
   even reach phase `Ready`. `testing/README.md` §1.1 lists which branch/commit each area needs
   — check `BASELINE.md`'s drift check before trusting that a branch is still what's deployed.
6. **A `Successful` op status is not proof.** Several bugs in this ledger are exactly a step
   that lies about its own outcome (mid-scale success, empty-database restore, no-op patches).
   Always check the actual observed state (etcdctl, pod template, file contents) in addition to
   the CR's condition.

## Which file do I read?

| Your task | Read |
|---|---|
| Run the full test plan / regression suite | `testing/README.md` (runnable, 40+ tests with real commands + results) + `testing/lib.sh` |
| Reproduce or verify the status of a specific known bug | `bugs.md` — symptom-indexed, each entry has repro steps and fix-commit (if any) |
| Test a specific `EtcdOpsRequest` type (Restart, MoveLeader, HorizontalScaling, ReconfigureTLS, RecoverFromQuorumLoss, ...) | `ops.md` for the type's live-status row, then the matching `O<N>` section in `testing/README.md` |
| Stand up a cluster / deploy the build you're about to test | `workflows.md` (build → side-load → deploy → activate loop) |
| Backup/restore or KubeStash-specific testing | `testing/README.md` §B1–B4 + `testing/manifests/backupconfig-etcd-only.yaml`, `kubestash-backup.yaml`, `s3-server.yaml` |
| TLS testing (issue/rotate/add/remove) | `testing/README.md` §O10 + `testing/manifests/cert-issuers.yaml` + `bugs.md` #9 |
| A symptom you're seeing and don't recognize | `bugs.md` first (symptom-indexed); if genuinely new, add it there in the same format |
| Confirm what's fixed vs still open before reporting results | `BASELINE.md` (pinned commits + drift check) + `bugs.md`'s header line |

## The 30-second model

One `Etcd` CR → the provisioner's `EtcdReconciler` renders a `PetSet` (`OnDelete`,
`podManagementPolicy` OrderedReady) running upstream etcd; Raft is the only HA mechanism (no
coordinator, no sidecar). Day-2 ops are `EtcdOpsRequest` (14 types), reconciled by a separate
`etcd-ops` binary that **no chart deploys for you** — `workflows.md` has the Deployment
manifest. Ports: client 2379, peer 2380, metrics 2381 (always plain http, useful for
unauthenticated health probes when RBAC blocks a credentialed client). Full model in
`workflows.md` and `ops.md`.

## Known-open bugs (do not re-report these as new findings)

See `bugs.md` for the full ledger and exact repro steps; check `BASELINE.md`'s drift check
first since fixes land on branches over time. As of this skill's last update, treat the header
line of `bugs.md` as the source of truth for what's currently open vs fixed — it is kept in
sync with the fix branches after every verification pass.
