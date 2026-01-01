#!/bin/bash
sudo kind delete cluster --name k8s-1.35 || true
sudo kind create cluster --name k8s-1.35 --config config.yaml
sudo kind get kubeconfig --name k8s-1.35 | tee ~/.kube/config >/dev/null
kubectl apply -f metric-server.yaml