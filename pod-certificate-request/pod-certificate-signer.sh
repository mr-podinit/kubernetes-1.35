#!/bin/bash
# See https://github.com/RafPe/pod-certificate-signer
# 1.35 supported version https://github.com/angeloxx/pod-certificate-signer

DEBIAN_FRONTEND=noninteractive
sudo apt install -yqq golang-cfssl
mkdir -p /tmp/pod-certificate-signer
cd /tmp/pod-certificate-signer || exit 1
cat <<\EOF | tee /tmp/pod-certificate-signer/ca-csr.json >/dev/null
{
  "CN": "Mr. PodInit CA",
  "key": {
    "algo": "ecdsa",
    "size": 256
  },
  "names": [
    {
      "C":  "CH",
      "L":  "Lugano",
      "O":  "Mr. PodInit CA",
      "ST": "Ticino"
    }
  ]
}
EOF

# Create with cfssl a self-signed CA
if [ ! -f /tmp/pod-certificate-signer/ca.pem ]; then
  echo "Creating self-signed CA certificate..."
  cfssl gencert -initca /tmp/pod-certificate-signer/ca-csr.json | cfssljson -bare ca
else
  echo "Self-signed CA certificate already exists, skipping creation."
fi

kubectl create namespace pcs-system
kubectl create secret --namespace pcs-system tls ca-secret --cert=/tmp/pod-certificate-signer/ca.pem --key=/tmp/pod-certificate-signer/ca-key.pem

echo "Deploying Pod Certificate Signer controller RBAC..."
cat <<\EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pcs
  namespace: pcs-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pcs-controller-role
rules:
# Events
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch

# Pods - need get for reading, patch/update for annotations
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
  - patch
  - update
  - list      # REQUIRED for watching
  - watch     # REQUIRED for watching

# PodCertificateRequests - monitor only
- apiGroups:
  - certificates.k8s.io
  resources:
  - podcertificaterequests
  verbs:
  - get
  - list
  - watch

# Status subresource - required for issuing certificates
- apiGroups:
  - certificates.k8s.io
  resources:
  - podcertificaterequests/status
  verbs:
  - update

# Finalizers
- apiGroups:
  - certificates.k8s.io
  resources:
  - podcertificaterequests/finalizers
  verbs:
  - update

# Signer permission - required
- apiGroups:
  - certificates.k8s.io
  resources:
  - signers
  resourceNames:
  - "k8s-135.podinit.sh/pcs"
  verbs:
  - sign

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: pcs-controller-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pcs-controller-role
subjects:
- kind: ServiceAccount
  namespace: pcs-system
  name: pcs
EOF

echo "Deploying Pod Certificate Signer controller..."
cat <<\EOF | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pcs-controller
  namespace: pcs-system
  labels:
    app: pcs-controller
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pcs-controller
  template:
    metadata:
      labels:
        app: pcs-controller
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - command:
        - /manager
        args:
          - --signer-name=k8s-135.podinit.sh/pcs
          - --ca-cert-path=/etc/ssl/ca/ca.pem
          - --ca-key-path=/etc/ssl/ca/ca-key.pem

        # Using a fork in order to support Kubernetes 1.35, the original project still supports up to 1.34
        image: angeloxx/kubernetes-podcertificate-signer:latest
        imagePullPolicy: IfNotPresent
        name: manager
        ports: []
        resources:
          limits:
            memory: 256Mi
          requests:
            memory: 32Mi
        securityContext:
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - "ALL"
        volumeMounts:
        - name: ca-secret
          mountPath: /etc/ssl/ca
          readOnly: true
      volumes:
      - name: ca-secret
        secret:
            secretName: ca-secret
            items:
            - key: tls.crt
              path: ca.pem
            - key: tls.key
              path: ca-key.pem
      dnsPolicy: Default
      nodeSelector:
        kubernetes.io/os: linux
      priorityClassName: system-cluster-critical
      restartPolicy: Always
      schedulerName: default-scheduler
      serviceAccountName: pcs
      terminationGracePeriodSeconds: 10
EOF