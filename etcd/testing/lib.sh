#!/usr/bin/env bash
# Helpers for the KubeDB etcd manual test plan (see README.md in this directory). Source this file:
#   source lib.sh
# Everything is read-only against the cluster except the functions that say otherwise.

export KUBECONFIG="${KUBECONFIG:-$HOME/k3s-80.yaml}"
export NS="${NS:-demo}"

# etcd password from the Etcd's CURRENT auth secret. The name comes from spec.authSecret.name,
# because RotateAuth with a user-supplied secret repoints the CR at a different secret than
# the default <db>-auth.
etcd_pw() {
  local sec; sec=$(kubectl get etcd -n "$NS" "$1" -o jsonpath='{.spec.authSecret.name}' 2>/dev/null)
  kubectl get secret -n "$NS" "${sec:-${1}-auth}" -o jsonpath='{.data.password}' | base64 -d
}

# ec <db> <ordinal> <etcdctl args...>      -> stdout only (safe to parse; stderr dropped)
# ecx <db> <ordinal> <etcdctl args...>     -> stdout+stderr merged (use to assert on errors)
# Runs etcdctl inside pod <db>-<ordinal>. The DB image has NO shell, so we exec etcdctl
# directly. Adds TLS flags when the Etcd has spec.tls, and root credentials always (with
# RBAC off, clientv3 swallows the "authentication is not enabled" reply on voters — but it
# logs a warning on stderr, which is why ec drops stderr).
ec() { _ec 2>/dev/null "$@"; }
ecx() { _ec 2>&1 "$@"; }
_ec() {
  local db=$1 ord=$2; shift 2
  local tls; tls=$(kubectl get etcd -n "$NS" "$db" -o jsonpath='{.spec.tls.issuerRef.name}' 2>/dev/null)
  local -a flags=(--user "root:$(etcd_pw "$db")")
  if [ -n "$tls" ]; then
    flags+=(--endpoints=https://localhost:2379
            --cacert=/var/run/etcd/tls/client/ca.crt
            --cert=/var/run/etcd/tls/client/tls.crt
            --key=/var/run/etcd/tls/client/tls.key)
  fi
  kubectl exec -n "$NS" "${db}-${ord}" -- etcdctl "${flags[@]}" "$@"
}

# wait_phase <db> <phase> [timeout-seconds]   -> 0 when the Etcd reaches <phase>
wait_phase() {
  local db=$1 want=$2 t=${3:-300} i=0 ph
  while [ $i -lt "$t" ]; do
    ph=$(kubectl get etcd -n "$NS" "$db" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$ph" = "$want" ] && { echo "phase=$ph after ${i}s"; return 0; }
    sleep 5; i=$((i+5))
  done
  echo "TIMEOUT waiting for phase=$want (last: ${ph:-none})"; return 1
}

# wait_ops <opsrequest> [timeout-seconds]   -> 0 on Successful, 1 on Failed/timeout
wait_ops() {
  local n=$1 t=${2:-600} i=0 ph
  while [ $i -lt "$t" ]; do
    ph=$(kubectl get etcdopsrequest -n "$NS" "$n" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$ph" in Successful) echo "ops $n Successful after ${i}s"; return 0;;
                  Failed)     echo "ops $n FAILED after ${i}s"; return 1;; esac
    sleep 5; i=$((i+5))
  done
  echo "TIMEOUT: ops $n phase=${ph:-none}"; return 1
}

# ops_conditions <opsrequest>   -> the state machine, with timestamps
ops_conditions() {
  kubectl get etcdopsrequest -n "$NS" "$1" \
    -o jsonpath='{range .status.conditions[*]}{.lastTransitionTime} {.type}={.status} {.message}{"\n"}{end}'
}

# members <db>  -> "name learner=<bool>" per member
members() { ec "$1" 0 member list | awk -F', ' '{print $3, "learner="$NF}' | sort; }

# leader_pod <db>  -> name of the current raft leader's pod
leader_pod() {
  local db=$1 lid
  lid=$(ec "$db" 0 endpoint status --cluster -w json | python3 -c \
    'import json,sys; print(json.load(sys.stdin)[0]["Status"]["leader"])')
  ec "$db" 0 member list -w json | python3 -c \
    'import json,sys; L=int(sys.argv[1]); print([m["name"] for m in json.load(sys.stdin)["members"] if m["ID"]==L][0])' "$lid"
}

# preflight <db> <expected-voters>
# The hard gate before ANY test: phase Ready is not evidence. Checks voter count, no learner,
# per-member health, a cross-member write/read, and equal revisions on every member.
preflight() {
  local db=$1 n=$2 ok=0
  local m; m=$(members "$db")
  [ "$(echo "$m" | grep -c 'learner=false')" = "$n" ] || { echo "PREFLIGHT FAIL: want $n voters, got:"; echo "$m"; ok=1; }
  echo "$m" | grep -q 'learner=true' && { echo "PREFLIGHT FAIL: learner present"; ok=1; }
  local i; for i in $(seq 0 $((n-1))); do
    ecx "$db" "$i" endpoint health | grep -q 'is healthy' || { echo "PREFLIGHT FAIL: ${db}-$i unhealthy"; ok=1; }
  done
  local stamp; stamp="pf-$(date +%s)"
  ec "$db" 0 put preflight "$stamp" >/dev/null
  [ "$(ec "$db" $((n-1)) get preflight --print-value-only)" = "$stamp" ] || { echo "PREFLIGHT FAIL: cross-member read"; ok=1; }
  sleep 2
  local revs; revs=$(for i in $(seq 0 $((n-1))); do ec "$db" "$i" endpoint status -w json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["Status"]["header"]["revision"])'; done | sort -u | wc -l)
  [ "$revs" = 1 ] || { echo "PREFLIGHT FAIL: revisions differ across members"; ok=1; }
  [ $ok = 0 ] && echo "PREFLIGHT OK ($n voters, healthy, replicated, equal revision)"
  return $ok
}

# load <db> <ordinal> <prefix> <count>   -> writes <count> keys (one etcdctl exec each; ~0.14s/key)
load() {
  local db=$1 ord=$2 pfx=$3 n=$4 i
  for i in $(seq 1 "$n"); do ec "$db" "$ord" put "$pfx/key-$i" "value-$i" >/dev/null || { echo "write failed at $i"; return 1; }; done
  echo "wrote $n keys under $pfx/"
}

# count <db> <ordinal> <prefix>  -> number of keys under the prefix, as seen by that member
count() { ec "$1" "$2" get "$3/" --prefix --count-only -w fields | awk '/Count/{print $3}'; }

# std_etcd <name> <replicas> [version]   -> applies a minimal Durable cluster (local-path)
std_etcd() {
  local name=$1 rep=$2 ver=${3:-3.6.4}
  kubectl apply -f - <<YAML
apiVersion: kubedb.com/v1alpha2
kind: Etcd
metadata: {name: $name, namespace: $NS}
spec:
  version: "$ver"
  replicas: $rep
  storageType: Durable
  storage:
    storageClassName: local-path
    accessModes: [ReadWriteOnce]
    resources: {requests: {storage: 1Gi}}
  deletionPolicy: WipeOut
YAML
}

# ops <name> <Type> <db> [extra spec yaml, indented 2 spaces]   -> creates an EtcdOpsRequest
ops() {
  local name=$1 type=$2 db=$3 extra=${4:-}
  kubectl apply -f - <<YAML
apiVersion: ops.kubedb.com/v1alpha1
kind: EtcdOpsRequest
metadata: {name: $name, namespace: $NS}
spec:
  type: $type
  databaseRef: {name: $db}
${extra}
YAML
}

# left <db>  -> names of every object still labelled/named for the db (empty = fully cleaned up)
left() {
  kubectl get pods,pvc,svc,cm,secret,sa,role,rolebinding,pdb,appbinding,petsets.apps.k8s.appscode.com,certificate \
    -n "$NS" 2>/dev/null | grep -E "(^|[/ ])${1}(-|[ ]|$)" | awk '{print $1}' | tr '\n' ' '
  echo
}

# clear_pause <db>   -> WORKAROUND for BUG 19 (a deleted in-flight ops request leaves the Etcd
# Paused forever and every apply:IfReady op then stays Pending). Removes the Paused condition.
clear_pause() {
  kubectl get etcd -n "$NS" "$1" -o json | python3 -c "
import json,sys,subprocess
o=json.load(sys.stdin); conds=[c for c in o['status']['conditions'] if c['type']!='Paused']
print(subprocess.run(['kubectl','patch','etcd','$1','-n','$NS','--subresource=status','--type=merge',
  '-p',json.dumps({'status':{'conditions':conds}})],capture_output=True,text=True).stdout.strip())"
}

# resources <db> <ordinal>  -> the etcd container's resources, uid and restart count of one pod
resources() {
  kubectl get pod -n "$NS" "${1}-${2}" -o jsonpath='uid={.metadata.uid} restarts={.status.containerStatuses[0].restartCount} res={.spec.containers[?(@.name=="etcd")].resources}{"\n"}'
}

# etcd_flags <db> <ordinal> [grep-pattern]  -> the etcd container's command-line flags
etcd_flags() {
  kubectl get pod -n "$NS" "${1}-${2}" -o jsonpath='{.spec.containers[?(@.name=="etcd")].args}' | tr ',' '\n' | tr -d '[]"' | grep -E "${3:-.}"
}
