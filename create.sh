#!/bin/bash
k8s_server_ip=10.211.55.8

# Remove k8s.
sudo kubeadm reset
./clearIptables.sh
sudo rm /etc/cni/ -rf
sudo reboot

# Install k8s.
sudo apt install -y kubeadm=1.24.4-00 kubectl=1.24.4-00 kubelet=1.24.4-00

sudo kubeadm init --control-plane-endpoint ${k8s_server_ip} --apiserver-advertise-address ${k8s_server_ip} --cri-socket /run/containerd/containerd.sock --pod-network-cidr=10.244.0.0/16
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Flannel
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
kubectl taint nodes --all node-role.kubernetes.io/control-plane- node-role.kubernetes.io/master-

# Longhorn
helm repo add longhorn https://charts.longhorn.io
helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace \
--set csi.attacherReplicaCount=1 \
--set csi.provisionerReplicaCount=1 \
--set csi.resizerReplicaCount=1 \
--set csi.snapshotterReplicaCount=1 \
--set defaultSettings.defaultReplicaCount=1 \
--set persistence.defaultClassReplicaCount=1

# Rook
git clone https://github.com/rook/rook.git
cd rook/deploy/examples
kubectl create -f crds.yaml -f common.yaml -f operator.yaml
kubectl create -f cluster-test.yaml
kubectrl create -f csi/rbd/storageclass-test.yaml
kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode && echo
kubectl create -f toolbox.yaml
cd ..

# MetalLB
kubectl create -f metallb-config.yaml
helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb

# Ingress
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace

# Test
k create deployment n --image nginx --port 80
k expose deployment n
k create ingress n --rule n/=n:80 --class nginx

# Harbor - no arm64
#helm repo add harbor https://helm.goharbor.io
#helm install harbor harbor/harbor --set expose.ingress.hosts.core=harbor --set externalURL=https://harbor --set internalTLS.enabled=true

# Dragonfly - no arm64
#helm repo add dragonfly https://dragonflyoss.github.io/helm-charts/
#helm install --create-namespace --namespace dragonfly-system dragonfly dragonfly/dragonfly -f dragonfly.yaml

# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd create ingress argocd-server --class nginx --rule argocd/*=argocd-server:443

# Tekton Pipeline
kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply --filename https://storage.googleapis.com/tekton-releases/dashboard/latest/tekton-dashboard-release.yaml
kubectl -n tekton-pipelines create ingress tekton --rule=tekton/*=tekton-dashboard:9097 --class 

# Tekton Trigger
kubectl apply --filename \
https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply --filename \
https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml

# Loki
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install loki --namespace=loki grafana/loki-simple-scalable --create-namespace --values loki/values.yaml 

# Grafana
helm install loki-grafana grafana/grafana --namespace=loki --create-namespace --set persistence.enabled=true
kubectl get secret --namespace loki loki-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
kubectl create -n loki ingress grafana --rule grafana/*=loki-grafana:80 --class nginx

# Promtail
helm upgrade --install promtail grafana/promtail --namespace loki
kubectl create -f promtail/bundle.yaml

# Tempo
helm upgrade --install tempo grafana/tempo --values tempo/tempo.yaml -n loki
helm upgrade -f microservices-tempo-values.yaml --install tempo grafana/tempo-distributed

# MinIO
# Username: admin 
# Password: 
krew install minio
kubectl minio init
kubectl minio tenant create tenant1 --servers 1 --volumes 2 --capacity 2Gi --namespace default
