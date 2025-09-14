#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="compliance-lab"
RANCHER_NAME="rancher"
DOMAIN="charon.butterflycluster.com"

CERT_DIR="/etc/ssl"
CERT_FILE="$CERT_DIR/butterflycluster_com.crt.pem"
KEY_FILE="$CERT_DIR/butterflycluster_com.key.pem"
CA_FILE="$CERT_DIR/butterflycluster_com.ca-bundle"

create_cluster() {
  echo ">>> Creating k3d cluster: $CLUSTER_NAME"
  k3d cluster create "$CLUSTER_NAME" --agents 1 --wait
  export KUBECONFIG=$(k3d kubeconfig write "$CLUSTER_NAME")

  echo ">>> Installing OpenEBS LocalPV Hostpath..."
  kubectl apply -f https://raw.githubusercontent.com/openebs/dynamic-localpv-provisioner/develop/deploy/kubectl/openebs-operator-lite.yaml

  echo ">>> Creating OpenEBS hostpath StorageClass..."
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-hostpath
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: openebs.io/local
parameters:
  StorageType: "hostpath"
  BasePath: "/var/openebs/local"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF

  echo ">>> Installing Rancher..."
  kubectl create namespace cattle-system || true
  helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
  helm upgrade --install rancher rancher-stable/rancher \
    --namespace cattle-system \
    --set hostname=$DOMAIN \
    --set bootstrapPassword=admin \
    --set ingress.tls.source=rancher \
    --set replicas=1

  echo ">>> Installing MinIO..."
  kubectl create ns minio || true
  helm repo add minio https://charts.min.io/
  helm upgrade --install minio minio/minio -n minio \
    --set accessKey=myaccesskey,secretKey=mysecretkey \
    --set defaultBucket.enabled=true

  echo ">>> Installing Velero..."
  velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.8.0 \
    --bucket velero \
    --secret-file ./manifests/minio-credentials \
    --use-volume-snapshots=false \
    --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.minio.svc.cluster.local:9000

  echo ">>> Installing Istio (demo profile)..."
  istioctl install --set profile=demo -y

  echo ">>> Installing Keycloak..."
  helm repo add codecentric https://codecentric.github.io/helm-charts
  helm upgrade --install keycloak codecentric/keycloakx -n keycloak --create-namespace \
    --set replicas=1 \
    --set ingress.enabled=true \
    --set ingress.hosts[0].host=$DOMAIN \
    --set ingress.hosts[0].paths[0].path=/

  echo ">>> Installing Vault..."
  helm repo add hashicorp https://helm.releases.hashicorp.com
  helm upgrade --install vault hashicorp/vault -n vault --create-namespace \
    --set server.dev.enabled=true

  echo ">>> Installing ELK..."
  helm repo add elastic https://helm.elastic.co
  helm upgrade --install elasticsearch elastic/elasticsearch -n elk --create-namespace
  helm upgrade --install kibana elastic/kibana -n elk

  echo ">>> Installing Fluent Bit..."
  helm repo add fluent https://fluent.github.io/helm-charts
  helm upgrade --install fluent-bit fluent/fluent-bit -n logging --create-namespace \
    --set backend.type=es \
    --set backend.es.host=elasticsearch-master.elk.svc.cluster.local

  echo ">>> Installing Prometheus Operator..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace

  echo ">>> Applying compliance manifests..."
  kubectl apply -f manifests/compliance-system.yaml
  kubectl apply -f manifests/compliance-test.yaml

  echo ">>> Cluster ready!"
  echo "Access Rancher at: https://$DOMAIN:8443"
}

destroy_cluster() {
  echo ">>> Deleting k3d cluster..."
  k3d cluster delete "$CLUSTER_NAME" || true

  echo ">>> Cleanup complete."
}

case "${1:-}" in
  up) create_cluster ;;
  down) destroy_cluster ;;
  reset) destroy_cluster && create_cluster ;;
  *) echo "Usage: $0 {up|down|reset}" ;;
esac