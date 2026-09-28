# Baseline & citation discipline

Facts in this skill were live-verified 2026-09-02/03 against the commits below. They are a
**provenance record**, not an addressing scheme — master moves.

**The durable address of a fact is the quoted symbol, never a line number.** This skill cites
`file › symbol`; resolve with `git grep -nF '<symbol>' -- <file>` (use `-F`: symbols carry Go
syntax a regex would eat). A symbol that no longer resolves marks a stale claim: re-derive it
from code, then fix the skill.

## Pinned commits (verification baseline, 2026-09-03)

| Repo | Path | Commit |
|---|---|---|
| `etcd` (master) | `$HOME/go/src/kubedb.dev/etcd` | `5cb73db9` = v0.1.0-rc.2 |
| `etcd` fix branch | `$HOME/go/src/kubedb.dev/etcd.worktrees/fix-psclient` | `c91fd76e` (`fix-psclient-provisioner-host`, 12 commits) |
| `apimachinery` | worktree `apimachinery.worktrees/etcd-dev` | `0fbe10cb4` (origin/master; main checkout is on `arnob-secret-pkg` with ZERO etcd code) |
| `provisioner` | worktree `provisioner.worktrees/etcd-dev`, branch `etcddev` | base `89da466a1` + vendor splices |
| `installer` | worktree `installer.worktrees/etcd-dev` | `f217866cf` (origin/master) |
| `webhook-server` | `$HOME/go/src/kubedb.dev/webhook-server` (checkout STALE) | origin/master `40d19ceb4` |
| `crd-manager` | clone, master | `5ff6c69d` |
| `etcd-restic-plugin` | clone, master | rc.2 (`00faabb`) |
| `etcd` restore fixes | `etcd.worktrees/fix-restore-task`, branch `fix-backup-restore-task-name` (on top of `fix-psclient-provisioner-host`) | `3a07bd4c` (task name), `ce1942d5` (dataDir) — unpushed as of 2026-09-25 |
| `etcd-restic-plugin` fixes | `etcd-restic-plugin.worktrees/verify`, branch `fix-appbinding-endpoint-scheme` | `0d92022` (endpoint scheme), `00390f2` (PVC target) — unpushed as of 2026-09-25 |
| `docs` | `$HOME/go/src/kubedb.dev/docs` master | etcd tree landed `a9593ffa` (#1050) |
| `etcd` quorum+pause fixes (bugs 11, 19) | `etcd.worktrees/fix-quorum-pause`, branch `fix-quorum-detect-and-resume-pause` (on top of `fix-backup-restore-task-name`) | `811410b7` — unpushed as of 2026-09-28 |
| `provisioner` bug-11 vendor splice | `provisioner.worktrees/etcd-dev-b11`, branch `etcddevb11` | base `89da466a1` + prior splices + uncommitted `health.go` splice — do not treat as a real provisioner commit |
| `webhook-server` bug-10 fix | `webhook-server.worktrees/fix-etcd-webhooks`, branch `fix-etcd-webhooks` | `a4f628d90` — unpushed as of 2026-09-28 |
| `installer` bug-10 chart fix | `installer.worktrees/etcd-dev`, branch `fix-etcd-autoscaler-webhook-configs` | `5c3a7c1b7` — unpushed as of 2026-09-28 |
| `kubedb-manifest-plugin` bug-15 fix | `kubedb-manifest-plugin.worktrees/fix-etcd-support`, branch `fix-etcd-support` (off master `5a757e23`) | `f8990fc8` — unpushed as of 2026-09-28, not yet cloned at baseline time (2026-09-03) |

Cross-repo PRs ALL MERGED (DESIGN.md §16 is stale): apimachinery#1870, db-client-go#261,
ops-manager#893, installer#2420, crd-manager#152, autoscaler#314, gitops#91,
kmodules/resource-metrics#98.

## Drift check (run first, read-only)

```bash
for r in etcd apimachinery provisioner installer webhook-server crd-manager; do
  d=$HOME/go/src/kubedb.dev/$r; git -C $d fetch origin -q
  echo "$r: $(git -C $d rev-list --count HEAD..origin/master 2>/dev/null) behind, on $(git -C $d branch --show-current || echo detached)"
done
```

Anything behind: check whether the fix branch commits (or equivalents) have merged before
trusting the bug list in `bugs.md` — each bug there names its fixing commit.

## What "verified" means here

Every ✅ in `ops.md` was executed on a live cluster (k3s-80) against the fix-branch builds,
with etcdctl-level evidence — not inferred from code or docs. The docs
(`docs/docs/guides/etcd/`, 78 pages) are stamped *"Drafted from source code … not yet
verified against a live cluster"*; treat them as leads. Docs bugs found so far: quickstart
uses `storageClassName: "standard"`; maintenance/scaling/rotate examples reference db
`etcd-cluster` while the quickstart creates `etcd-quickstart`.
