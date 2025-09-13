apiVersion: v1
kind: Namespace
metadata:
  name: compliance-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: collector
  namespace: compliance-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: compliance-collector-readonly
rules:
- apiGroups: [""]
  resources: ["pods","services","endpoints","persistentvolumeclaims","events","namespaces","nodes","secrets"]
  verbs: ["get","list","watch"]
- apiGroups: ["apps"]
  resources: ["deployments","statefulsets","daemonsets","replicasets"]
  verbs: ["get","list","watch"]
- apiGroups: ["policy"]
  resources: ["poddisruptionbudgets"]
  verbs: ["get","list","watch"]
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies","ingresses"]
  verbs: ["get","list","watch"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles","rolebindings","clusterroles","clusterrolebindings"]
  verbs: ["get","list","watch"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get","list","watch"]
- apiGroups: ["velero.io"]
  resources: ["schedules","backups"]
  verbs: ["get","list","watch"]
- apiGroups: ["monitoring.coreos.com"]
  resources: ["servicemonitors","prometheusrules"]
  verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: compliance-collector-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: compliance-collector-readonly
subjects:
- kind: ServiceAccount
  name: collector
  namespace: compliance-system