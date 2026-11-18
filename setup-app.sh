#!/bin/bash
set -e
echo "============================================"
echo " ECM CI/CD - Déploiement Application"
echo "============================================"

echo "[1/5] Namespace..."
kubectl apply -f k8s/namespace/namespace.yaml

echo "[2/5] Build image Docker..."
docker build -t localhost:5001/ecm-backend:latest app/backend/
docker push localhost:5001/ecm-backend:latest

echo "[3/5] PostgreSQL..."
kubectl apply -f k8s/postgresql/postgresql.yaml
kubectl wait --namespace ecm --for=condition=ready pod --selector=app=postgresql --timeout=120s

echo "[4/5] MinIO..."
kubectl apply -f k8s/minio/minio.yaml
kubectl wait --namespace ecm --for=condition=ready pod --selector=app=minio --timeout=120s

echo "[5/5] ECM Backend..."
kubectl apply -f k8s/backend/backend.yaml
kubectl wait --namespace ecm --for=condition=ready pod --selector=app=ecm-backend --timeout=120s

echo ""
kubectl get pods -n ecm
echo ""
echo "============================================"
echo " Application ECM déployée !"
echo " Test : curl http://localhost:8080/health -H 'Host: ecm.local'"
echo "============================================"
