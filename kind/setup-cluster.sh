#!/bin/bash
set -e
CLUSTER_NAME="ecm-cluster"
REGISTRY_NAME="kind-registry"
REGISTRY_PORT="5001"

echo "============================================"
echo " ECM CI/CD - Setup Cluster Kind"
echo "============================================"

echo "[1/5] Registry locale..."
if [ "$(docker inspect -f '{{.State.Running}}' ${REGISTRY_NAME} 2>/dev/null)" != "true" ]; then
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --network bridge --name "${REGISTRY_NAME}" registry:2
  echo "  Registry démarrée sur localhost:${REGISTRY_PORT}"
else
  echo "  Registry déjà active"
fi

echo "[2/5] Cluster Kind..."
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "  Cluster ${CLUSTER_NAME} existe déjà"
else
  kind create cluster --config kind/cluster-config.yaml
fi

echo "[3/5] Connexion registry au réseau Kind..."
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' ${REGISTRY_NAME})" = 'null' ]; then
  docker network connect kind ${REGISTRY_NAME}
fi

echo "[4/5] ConfigMap registry..."
kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
YAML

echo "[5/5] Ingress NGINX..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

echo "============================================"
echo " Cluster ECM prêt !"
echo " Registry : localhost:${REGISTRY_PORT}"
echo " Ingress  : http://localhost:8080"
echo "============================================"
