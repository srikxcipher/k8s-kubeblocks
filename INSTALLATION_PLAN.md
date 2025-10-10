# KubeBlocks Installation Plan - Helm & kubectl Only

## Current Environment
- **Kubernetes Version**: v1.31.13 (EKS)
- **kubectl Version**: v1.33.3
- **Tools**: kubectl, Helm 3
- **Platform**: AWS EKS

## Problem Analysis

### Previous Issue
The initial installation had a critical version mismatch:
- **KubeBlocks Controller**: v1.0.1 (expects API version `v1`)
- **CRDs Installed**: Only supported `v1alpha1` API
- **Result**: Controller couldn't manage resources, PostgreSQL addon failed

### Root Cause
KubeBlocks 1.0.x was built expecting `v1` APIs but the CRDs shipped with it only provide `v1alpha1`. This is a packaging issue in the 1.0.x release series.

## Recommended Solution: KubeBlocks 0.9.5

### Why 0.9.5?
- ✅ **Stable and mature** release
- ✅ **Consistent API versions** - all components use `v1alpha1`
- ✅ **Well-tested** PostgreSQL addon compatibility
- ✅ **Production-ready** with proven track record
- ✅ **Compatible** with Kubernetes 1.31

## Version Compatibility Matrix

| KubeBlocks | CRD API | PostgreSQL Addon | Controller Expects | Status |
|-----------|---------|------------------|-------------------|---------|
| 1.0.1 | v1alpha1 | 1.0.1, 1.0.2 | v1 | ❌ **BROKEN** |
| 0.9.5 | v1alpha1 | 0.9.5, 0.9.7 | v1alpha1 | ✅ **STABLE** |
| 0.9.0 | v1alpha1 | 0.9.0 | v1alpha1 | ✅ STABLE |
| 0.8.4 | v1alpha1 | 0.8.3 | v1alpha1 | ✅ STABLE |

## Installation Plan

### Prerequisites
```bash
# Verify Helm repos are configured
helm repo list | grep kubeblocks

# Expected output:
# kubeblocks        https://apecloud.github.io/helm-charts
# kubeblocks-addons https://jihulab.com/api/v4/projects/150246/packages/helm/stable

# Update repos
helm repo update
```

---

## Phase 1: Install KubeBlocks Core 0.9.5

### Step 1.1: Install KubeBlocks via Helm
```bash
helm install kubeblocks kubeblocks/kubeblocks \
  --namespace kb-system \
  --create-namespace \
  --version 0.9.5 \
  --wait
```

**Expected Output:**
```
NAME: kubeblocks
NAMESPACE: kb-system
STATUS: deployed
REVISION: 1
```

### Step 1.2: Verify KubeBlocks Installation
```bash
# Check namespace
kubectl get namespace kb-system

# Check pods
kubectl get pods -n kb-system

# Expected pods:
# kubeblocks-xxxx                  Running
# kubeblocks-dataprotection-xxxx   Running
```

### Step 1.3: Verify CRDs Installed
```bash
# List KubeBlocks CRDs
kubectl get crd | grep kubeblocks.io

# Check API versions
kubectl api-resources --api-group=apps.kubeblocks.io

# Verify all show v1alpha1 (NOT v1)
```

**Expected CRDs (partial list):**
- clusterdefinitions.apps.kubeblocks.io
- clusters.apps.kubeblocks.io
- componentdefinitions.apps.kubeblocks.io
- componentversions.apps.kubeblocks.io
- components.apps.kubeblocks.io
- configconstraints.apps.kubeblocks.io

### Step 1.4: Check Controller Logs
```bash
# Verify no API version errors
kubectl logs -n kb-system deployment/kubeblocks --tail=50

# Should NOT see errors like:
# "no matches for kind in version v1"
```

---

## Phase 2: Install PostgreSQL Addon 0.9.5

### Step 2.1: Install PostgreSQL Addon
```bash
helm install kb-addon-postgresql kubeblocks-addons/postgresql \
  --version 0.9.5 \
  --namespace kb-system \
  --wait
```

**Expected Output:**
```
NAME: kb-addon-postgresql
NAMESPACE: kb-system
STATUS: deployed
REVISION: 1
```

### Step 2.2: Verify PostgreSQL Resources
```bash
# Check ClusterDefinition
kubectl get clusterdefinition postgresql

# Expected output shows API version v1alpha1:
# NAME         TOPOLOGIES   SERVICEREFS   STATUS   AGE
# postgresql                                       10s

# Check ComponentDefinitions
kubectl get componentdefinition | grep postgresql

# Expected output:
# postgresql-12   postgresql   12.15.0   10s
# postgresql-14   postgresql   14.8.0    10s
# postgresql-15   postgresql   15.7.0    10s
# postgresql-16   postgresql   16.4.0    10s

# Verify API version
kubectl get clusterdefinition postgresql -o jsonpath='{.apiVersion}'
# Expected: apps.kubeblocks.io/v1alpha1
```

### Step 2.3: Check ConfigConstraints
```bash
kubectl get configconstraint | grep postgresql

# Expected:
# postgresql12-cc
# postgresql14-cc
# postgresql15-cc
# postgresql16-cc
```

### Step 2.4: Verify No Failed Pods
```bash
kubectl get pods -n kb-system

# All pods should be Running
# No Error or CrashLoopBackOff status
```

---

## Phase 3: Create Test PostgreSQL Cluster

### Step 3.1: Create Test Namespace
```bash
kubectl create namespace demo
```

### Step 3.2: Create Cluster Manifest
Create file: `postgresql-test-cluster.yaml`

```yaml
apiVersion: apps.kubeblocks.io/v1alpha1
kind: Cluster
metadata:
  name: pg-test
  namespace: demo
spec:
  clusterDefinitionRef: postgresql
  clusterVersionRef: postgresql-14.8.0
  terminationPolicy: Delete
  componentSpecs:
    - name: postgresql
      componentDefRef: postgresql-14
      replicas: 1
      resources:
        limits:
          cpu: "1"
          memory: "1Gi"
        requests:
          cpu: "500m"
          memory: "512Mi"
      volumeClaimTemplates:
        - name: data
          spec:
            accessModes:
              - ReadWriteOnce
            resources:
              requests:
                storage: 1Gi
```

### Step 3.3: Deploy Test Cluster
```bash
kubectl apply -f postgresql-test-cluster.yaml

# Watch cluster creation
kubectl get cluster -n demo -w

# Expected progression:
# STATUS: Creating -> Running
```

### Step 3.4: Verify Cluster Components
```bash
# Check Cluster resource
kubectl get cluster -n demo

# Expected:
# NAME      CLUSTER-DEFINITION   VERSION             TERMINATION-POLICY   STATUS    AGE
# pg-test   postgresql           postgresql-14.8.0   Delete               Running   2m

# Check Component
kubectl get component -n demo

# Expected:
# NAME              CLUSTER   TYPE         STATUS    AGE
# pg-test-postgresql pg-test   postgresql   Running   2m

# Check Pods
kubectl get pods -n demo

# Expected:
# NAME                   READY   STATUS    RESTARTS   AGE
# pg-test-postgresql-0   2/2     Running   0          2m
```

### Step 3.5: Verify Services
```bash
kubectl get svc -n demo

# Expected services:
# pg-test-postgresql           ClusterIP
# pg-test-postgresql-headless  ClusterIP (None)
```

### Step 3.6: Check PVCs
```bash
kubectl get pvc -n demo

# Expected:
# NAME                                STATUS   VOLUME   CAPACITY
# data-pg-test-postgresql-0           Bound    pvc-xxx  1Gi
```

---

## Phase 4: Validation & Testing

### Step 4.1: Check Pod Logs
```bash
kubectl logs -n demo pg-test-postgresql-0 -c postgresql

# Should show PostgreSQL startup logs
# Look for: "database system is ready to accept connections"
```

### Step 4.2: Test Database Connection
```bash
# Get the connection credentials from secret
kubectl get secret -n demo pg-test-conn-credential -o jsonpath='{.data.password}' | base64 -d
echo

# Connect to PostgreSQL
kubectl exec -it -n demo pg-test-postgresql-0 -c postgresql -- psql -U postgres

# Inside psql, run:
# \l          -- List databases
# \dt         -- List tables
# SELECT version();
# \q          -- Quit
```

### Step 4.3: Check Cluster Status Details
```bash
kubectl describe cluster pg-test -n demo

# Look for:
# - Status: Running
# - Conditions: All showing True/Healthy
# - Events: No errors
```

---

## Success Criteria Checklist

- [ ] KubeBlocks controller pod Running in kb-system
- [ ] KubeBlocks dataprotection pod Running in kb-system
- [ ] All CRDs using v1alpha1 API (verified with kubectl api-resources)
- [ ] No API version errors in controller logs
- [ ] PostgreSQL ClusterDefinition created
- [ ] PostgreSQL ComponentDefinitions created (versions 12, 14, 15, 16)
- [ ] Test cluster status: Running
- [ ] Test PostgreSQL pod status: 2/2 Running
- [ ] PostgreSQL service accessible
- [ ] PVC bound and storage allocated
- [ ] Database accepting connections
- [ ] No error events in cluster description

---

## Verification Commands Summary

```bash
# Quick health check script
echo "=== KubeBlocks Health Check ==="
echo ""
echo "1. KB Pods:"
kubectl get pods -n kb-system
echo ""
echo "2. API Versions:"
kubectl api-resources --api-group=apps.kubeblocks.io | grep -E "NAME|cluster|component"
echo ""
echo "3. PostgreSQL Resources:"
kubectl get clusterdefinition,componentdefinition -l app.kubernetes.io/instance=kb-addon-postgresql
echo ""
echo "4. Test Cluster:"
kubectl get cluster,component,pod,svc,pvc -n demo
echo ""
echo "5. Controller Errors:"
kubectl logs -n kb-system deployment/kubeblocks --tail=20 | grep -i error || echo "No errors found"
```

---

## Troubleshooting

### If Installation Fails

#### Check Controller Logs
```bash
kubectl logs -n kb-system deployment/kubeblocks --tail=100
```

#### Common Issues

**Issue 1: API Version Mismatch**
```bash
# Symptom: Error "no matches for kind in version v1"
# Solution: Verify you're using 0.9.5, not 1.0.x
helm list -n kb-system
kubectl get crd clusterdefinitions.apps.kubeblocks.io -o jsonpath='{.spec.versions[*].name}'
```

**Issue 2: Cluster Not Starting**
```bash
# Check component status
kubectl describe component -n demo

# Check events
kubectl get events -n demo --sort-by='.lastTimestamp'
```

**Issue 3: Pod CrashLooping**
```bash
# Check pod logs
kubectl logs -n demo pg-test-postgresql-0 -c postgresql --previous

# Check pod events
kubectl describe pod -n demo pg-test-postgresql-0
```

---

## Rollback Procedure

### Complete Cleanup
```bash
# 1. Delete test cluster
kubectl delete cluster pg-test -n demo
kubectl delete namespace demo

# 2. Uninstall PostgreSQL addon
helm uninstall kb-addon-postgresql -n kb-system

# 3. Uninstall KubeBlocks
helm uninstall kubeblocks -n kb-system

# 4. Delete namespace
kubectl delete namespace kb-system

# 5. Clean up CRDs
kubectl get crd | grep kubeblocks.io | awk '{print $1}' | \
  while read crd; do kubectl patch crd $crd -p '{"metadata":{"finalizers":[]}}' --type=merge; done

kubectl get crd | grep kubeblocks.io | awk '{print $1}' | xargs kubectl delete crd
```

### Verify Cleanup
```bash
# Should return no results
kubectl get crd | grep kubeblocks.io
kubectl get namespace kb-system
helm list -A | grep kubeblocks
```

---

## Post-Installation Next Steps

1. **Configure Monitoring**
   - Install Prometheus addon if needed
   - Install Grafana addon for visualization

2. **Set Up Backups**
   - Configure BackupPolicy
   - Set up backup schedules
   - Test restore procedures

3. **Implement RBAC**
   - Create appropriate roles and service accounts
   - Limit access to sensitive resources

4. **Document Operations**
   - Backup/restore procedures
   - Scaling procedures
   - Upgrade procedures

5. **Production Readiness**
   - Configure resource limits
   - Set up monitoring alerts
   - Implement disaster recovery plan

---

## Important Notes

- **Always use matching versions**: KubeBlocks 0.9.5 + PostgreSQL addon 0.9.5
- **API version must be v1alpha1**: Verify with `kubectl api-resources`
- **Never mix 1.0.x with 0.9.x**: They use incompatible APIs
- **Test in non-production first**: Validate the full stack before production use
- **Keep Helm repos updated**: Run `helm repo update` regularly

## Reference

- **KubeBlocks Chart**: https://github.com/apecloud/helm-charts
- **PostgreSQL Addon**: https://github.com/apecloud/kubeblocks-addons
- **Documentation**: https://kubeblocks.io/docs/preview/user_docs/overview/introduction
