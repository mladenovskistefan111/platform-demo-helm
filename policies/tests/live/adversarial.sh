#!/usr/bin/env bash
# Live admission tests against a cluster that runs the policies (server-side dry-runs and impersonated requests: nothing is
# created). Complements the offline unit tests (policies/tests/*/kyverno-test.yaml), which cannot see the admission request
# (user, subresource) or the signature check. Run it after changing a policy:   policies/tests/live/adversarial.sh
# Needs cluster-admin. Prints PASS/FAIL per case and exits 1 on any FAIL.
set -u
NS=${NS:-platform-demo}
fails=0
GOOD=$(kubectl -n "$NS" get deploy checkout-service -o jsonpath='{.spec.template.spec.containers[0].image}')
DBIMG=$(kubectl -n "$NS" get sts product-catalog-db -o jsonpath='{.spec.template.spec.containers[0].image}')
VERIFY=$(kubectl get ivpol pd-verify-images -o jsonpath='{.spec.validationActions[0]}' 2>/dev/null)

chk() { # name expected(deny|allow) output [policy or phrase the denial must come from]
  local verdict=allow
  grep -qiE "denied the request|forbidden|is blocked|may not " <<<"$3" && verdict=deny
  if [ "$verdict" = "$2" ] && { [ "$2" = allow ] || [ -z "${4:-}" ] || grep -q -- "$4" <<<"$3"; }; then
    printf 'PASS  %-62s %s\n' "$1" "$(grep -oE 'Policy [a-z-]+ failed: .{0,60}|may not [a-z]+ [a-z]+|is blocked|violates PodSecurity.{0,30}' <<<"$3" | head -1)"
  else
    printf 'FAIL  %-62s expected %s%s, got: %s\n' "$1" "$2" "${4:+ by $4}" "$(head -c 240 <<<"$3")"; fails=$((fails+1))
  fi
}
pod() { # name label serviceaccount image
cat <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $1, namespace: $NS, labels: { app.kubernetes.io/name: $2 } }
spec:
  serviceAccountName: $3
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 100, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: c
      image: "$4"
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 32Mi } }
      readinessProbe: { tcpSocket: { port: 8080 } }
      livenessProbe: { tcpSocket: { port: 8080 } }
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
EOF
}
dry() { kubectl apply --dry-run=server -f - 2>&1; }
DIG=sha256:0000000000000000000000000000000000000000000000000000000000000000

echo "== pod identity (Cilium identity is label-derived)"
chk "compliant pod with the right identity"                     allow "$(pod t1 checkout-service checkout-service "$GOOD" | dry)"
chk "stolen label (frontend), default ServiceAccount"           deny  "$(pod t2 frontend default "$GOOD" | dry)" "pd-pod-identity"
chk "stolen label (frontend), another workload's ServiceAccount" deny "$(pod t3 frontend checkout-service "$GOOD" | dry)" "pd-pod-identity"
chk "unknown app name 'miner'"                                  deny  "$(pod t4 miner default "$GOOD" | dry)" "pd-pod-identity"
FE=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=frontend -o name | head -1)
chk "relabel a running frontend pod as checkout-service"        deny  "$(kubectl -n "$NS" label "$FE" app.kubernetes.io/name=checkout-service --overwrite --dry-run=server 2>&1)" "pd-pod-identity"

echo "== image sources and signatures"
chk "foreign registry"                                          deny  "$(pod t5 checkout-service checkout-service "evil.io/x/miner@$DIG" | dry)" "pd-image-source"
chk "other Docker Hub repository"                               deny  "$(pod t6 checkout-service checkout-service "someone/else@$DIG" | dry)" "pd-image-source"
chk "tag instead of digest"                                     deny  "$(pod t7 checkout-service checkout-service "busybox:1.37.0" | dry)" "pd-image-source"
chk "our unsigned DB image under the wrong identity"            "$([ "$VERIFY" = Deny ] && echo deny || echo allow)" "$(pod t8 checkout-service checkout-service "$DBIMG" | dry)" "$([ "$VERIFY" = Deny ] && echo pd-verify-images)"
chk "our unsigned DB image under its own identity (exception)"  allow "$(pod t9 product-catalog-db product-catalog-db "$DBIMG" | dry)"
[ "$VERIFY" = Deny ] || echo "NOTE  pd-verify-images is $VERIFY here: unsigned-image cases only warn (see policies/README.md, Docker Hub rate limit)"

echo "== pod hardening"
chk "container without probes"                                  deny  "$(pod t10 checkout-service checkout-service "$GOOD" | sed '/Probe:/d' | dry)" "pd-require-probes"
chk "writable root filesystem"                                  deny  "$(pod t11 checkout-service checkout-service "$GOOD" | sed 's/readOnlyRootFilesystem: true/readOnlyRootFilesystem: false/' | dry)" "pd-readonly-rootfs"
chk "API token mounted"                                         deny  "$(pod t12 checkout-service checkout-service "$GOOD" | sed 's/automountServiceAccountToken: false/automountServiceAccountToken: true/' | dry)" "pd-service-account"
chk "privileged container (Pod Security + Kyverno)"             deny  "$(pod t13 checkout-service checkout-service "$GOOD" | sed 's/allowPrivilegeEscalation: false/privileged: true/' | dry)" "PodSecurity"
chk "no resources declared (LimitRange fills the defaults)"     allow "$(pod t14 checkout-service checkout-service "$GOOD" | sed '/resources:/d' | dry)"

echo "== exposure and network policy"
chk "Service type NodePort"                                     deny  "$(kubectl -n "$NS" create service nodeport np --tcp=80:80 --dry-run=server 2>&1)" "pd-restrict-service-types"
chk "Service type LoadBalancer"                                 deny  "$(kubectl -n "$NS" create service loadbalancer lb --tcp=80:80 --dry-run=server 2>&1)" "pd-restrict-service-types"
route() { cat <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: r, namespace: $NS }
spec:
  parentRefs: [{ name: platform-gateway, namespace: gateway-system }]
  hostnames: [$1]
  rules: [{ backendRefs: [{ name: frontend, port: 80 }] }]
EOF
}
chk "HTTPRoute for a foreign host"                              deny  "$(route bank.example.com | dry)" "pd-restrict-route-hostnames"
chk "HTTPRoute for our domain"                                  allow "$(route shop2.platform-demo.click | dry)"
kubectl -n "$NS" create role pd-test-cnp --verb='*' --resource=ciliumnetworkpolicies.cilium.io >/dev/null 2>&1
kubectl -n "$NS" create rolebinding pd-test-cnp --role=pd-test-cnp --user=mallory >/dev/null 2>&1
CNP="apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: open-up, namespace: $NS }
spec: { endpointSelector: {}, ingress: [{ fromEntities: [world] }] }"
sleep 2
chk "non-admin user creates an allow-all CiliumNetworkPolicy"   deny  "$(kubectl --as=mallory --as-group=system:authenticated apply --dry-run=server -f - 2>&1 <<<"$CNP")" "pd-protect-network-policy"
chk "cluster admin creates a CiliumNetworkPolicy"               allow "$(kubectl apply --dry-run=server -f - 2>&1 <<<"$CNP")"
kubectl -n "$NS" delete rolebinding pd-test-cnp >/dev/null 2>&1; kubectl -n "$NS" delete role pd-test-cnp >/dev/null 2>&1

echo "== namespaces"
chk "workload namespace without Pod Security 'restricted'"      deny  "$(kubectl apply --dry-run=server -f - 2>&1 <<<'{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"sneaky","labels":{"platform.demo/profile":"workload"}}}')" "pd-namespace-pod-security"
chk "remove the Pod Security label from $NS"                    deny  "$(kubectl label ns "$NS" pod-security.kubernetes.io/enforce- --dry-run=server 2>&1)" "pd-namespace-pod-security"
chk "ordinary label change on argocd (must stay possible)"      allow "$(kubectl label ns argocd pd-test=1 --overwrite --dry-run=server 2>&1)"

echo "== gVisor sandbox (mutation by namespace label platform.demo/sandbox=gvisor)"
rc() { grep -o 'runtimeClassName: [a-z]*' <<<"$1" | head -1; }  # server-side dry-run echoes the mutated pod with -o yaml
SB=$(pod sb1 checkout-service checkout-service "$GOOD" | kubectl apply --dry-run=server -o yaml -f - 2>&1)
chk "pod in a labelled namespace gets runtimeClassName gvisor"  allow "$([ "$(rc "$SB")" = "runtimeClassName: gvisor" ] && echo ok || echo "got: $(rc "$SB") $(head -c 120 <<<"$SB")")"
SB=$(pod sb2 checkout-service checkout-service "$GOOD" | sed 's/^metadata: {/metadata: { annotations: { platform.demo\/sandbox: disabled },/' | kubectl apply --dry-run=server -o yaml -f - 2>&1)
chk "opt-out annotation keeps the pod out of the sandbox"       allow "$([ -z "$(rc "$SB")" ] && echo ok || echo "got: $(rc "$SB")")"

echo "== break-glass (exec / attach / debug)"
POD=cart-redis-0
chk "kubectl exec without the annotation"                       deny  "$(kubectl -n "$NS" exec "$POD" -- true 2>&1)" "pd-no-exec-without-break-glass"
kubectl -n "$NS" annotate pod "$POD" platform.demo/break-glass=true >/dev/null 2>&1
chk "kubectl exec WITH platform.demo/break-glass=true"          allow "$(kubectl -n "$NS" exec "$POD" -- true 2>&1)"
kubectl -n "$NS" annotate pod "$POD" platform.demo/break-glass- >/dev/null 2>&1
chk "kubectl exec after the annotation is removed"              deny  "$(kubectl -n "$NS" exec "$POD" -- true 2>&1)" "pd-no-exec-without-break-glass"
chk "kubectl debug (ephemeral container)"                       deny  "$(kubectl -n "$NS" debug "$POD" --image=busybox --target=cart-redis --profile=restricted 2>&1 | head -5)" "pd-no-exec-without-break-glass"

echo; [ "$fails" -eq 0 ] && echo "all cases passed" || echo "$fails case(s) FAILED"
exit $((fails>0))
