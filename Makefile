# Include environment variables
ENV	:= $(PWD)/.env
include $(ENV)
OS := $(shell uname -s)

# Debian/Ubuntu prerequisites
install_prerequisites:
	@echo "Install basic prerequisites"
	sudo apt-get update
	sudo apt-get install git neovim build-essential make

# Debian/Ubuntu docker prerequisites
install_docker:
	@echo "Install Docker"
	sudo apt-get update
	sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
	sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $$(lsb_release -cs) stable"
	sudo apt-get update
	sudo apt-get install -y docker-ce
	sudo usermod -aG docker $${USER}
	@echo "Docker was installed. Please logout and login again"

# The cross plaform package manager
install_brew:
	@echo "Install Homebrew"
	/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Create a local Kubernetes cluster
cluster_local:
	@echo "Creating local Kubernetes cluster"
	kind create cluster --config ./kind/cluster-local.yaml

# Set the proper domain name
domain_name:
	find devops-app -type f -name "*.yaml" -exec sed -i 's/devops.toys/$(DOMAIN_NAME)/g' {} \;
	git add .
	git commit -m "Change domain name"
	git push

# Configure the local Kubernetes cluster
initial_setup:
	helm repo add argo https://argoproj.github.io/argo-helm
	helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait
	kustomize build ./devops-app/devops-app | kubectl apply -f -
	kubectl create namespace cert-manager
	kubectl create namespace minio
	kubectl create namespace sonarqube
	kubectl create namespace metallb-system
	kubectl create namespace monitoring
	kubectl create namespace ingress-nginx
	kustomize build ./devops-app/kube-prometheus-stack | kubectl apply -f -
	kustomize build ./devops-app/ingress-nginx | kubectl apply -f -
	kustomize build ./devops-app/sealed-secrets | kubectl apply -f -
	kustomize build ./devops-app/cert-manager | kubectl apply -f -
	kustomize build ./devops-app/metallb | kubectl apply -f -
	kustomize build ./devops-app/trust-manager | kubectl apply -f -
	kustomize build ./devops-app/cnpg | kubectl apply -f -
	# TODO: Find a better solution - wait for cert-manager
	sleep 180

# Configure the ArgoCD repository
add_repo:
	kubectl --namespace argocd \
	create secret \
	generic repo-devops-tools \
	--from-literal=type=git \
	--from-literal=url=git@github.com:$(GITHUB_USERNAME)/devops-toys.git \
	--from-file=sshPrivateKey=devops-toys \
	--dry-run=client -oyaml | \
	kubeseal --format yaml \
	--controller-name=sealed-secrets \
	--controller-namespace=sealed-secrets -oyaml - | \
	kubectl patch -f - \
	-p '{"spec": {"template": {"metadata": {"labels": {"argocd.argoproj.io/secret-type":"repository"}}}}}' \
	--dry-run=client \
	--type=merge \
	--local -oyaml > ./devops-app/bootstrap/manifests/repo-devops-toys.yaml
	git add ./devops-app/bootstrap/manifests/repo-devops-toys.yaml
	git commit -m "Add devops-toys repo to Argocd"
	git push

ca: ca_key ca_cert ca_cert_secret ca_trusted

# Generate a CA key
ca_key:
	openssl genrsa -out ca.key 4096

# Generate a CA certificate
ca_cert:
	openssl req -new -x509 -sha256 -days 3650 \
  	-key ca.key \
  	-out ca.crt \
  	-subj '/CN=$(CN)/emailAddress=$(GITHUB_EMAIL)/C=$(C)/ST=$(ST)/L=$(L)/O=$(O)/OU=$(OU)'

# Create a CA certificate secret
ca_cert_secret:
	kubectl --namespace cert-manager \
  create secret \
  generic local.devops-ca \
  --from-file=tls.key=ca.key \
  --from-file=tls.crt=ca.crt \
  --output json \
  --dry-run=client | \
  kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets | \
  tee devops-app/bootstrap/manifests/ca-secret.yaml
	kubectl apply -f ./devops-app/bootstrap/manifests/ca-secret.yaml
	git add ./devops-app/bootstrap/manifests/ca-secret.yaml
	git commit -m "Add CA cert secret"
	git push

# Add the CA certificate to the trusted certificates
ca_trusted:
	# For Arch Linux
	sudo cp ca.crt /etc/ca-certificates/trust-source/anchors
	sudo update-ca-trust
	# For Debian/Ubuntu
	#sudo cp ca.crt /usr/local/share/ca-certificates
	#sudo update-ca-certificates

minio: minio_users minio_root

# Create a MinIO user secret
minio_users:
	kubectl --namespace minio \
		create secret \
		generic centralized-minio-users \
		--from-file=user=/dev/stdin <<< $$(echo -e "username=${MINIO_USERNAME}\npassword=${MINIO_PASSWORD}\ndisabled=false\npolicies=readwrite,consoleAdmin,diagnostics\nsetPolicies=false") \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/bootstrap/manifests/minio-users-secret.yaml
	kubectl apply -f ./devops-app/bootstrap/manifests/minio-users-secret.yaml
	git add ./devops-app/bootstrap/manifests/minio-users-secret.yaml
	git commit -m "Add MinIO users secret"
	git push

# Create a MinIO root user secret
minio_root:
	kubectl --namespace minio \
		create secret \
		generic minio-root \
		--from-literal=root-user=$(MINIO_ROOT_USER) \
		--from-literal=root-password=$(MINIO_ROOT_PASSWORD) \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/bootstrap/manifests/minio-root-secret.yaml
	kubectl apply -f ./devops-app/bootstrap/manifests/minio-root-secret.yaml
	git add ./devops-app/bootstrap/manifests/minio-root-secret.yaml
	git commit -m "Add MinIO root credentials"
	git push

sonarqube: sonarqube_psql_backup sonarqube_credentials

# Create a SonarQube PostgreSQL backup secret
sonarqube_psql_backup:
	kubectl --namespace sonarqube \
		create secret \
		generic minio-creds \
		--from-literal=accesskey=${MINIO_USERNAME} \
		--from-literal=secretkey=${MINIO_PASSWORD} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/bootstrap/manifests/sonarqube-psql-backup.yaml
	kubectl apply -f ./devops-app/bootstrap/manifests/sonarqube-psql-backup.yaml
	git add ./devops-app/bootstrap/manifests/sonarqube-psql-backup.yaml
	git commit -m "Add SonarQube PostgreSQL backup credentials"
	git push

# Create a SonarQube admin password secret
sonarqube_credentials:
	kubectl --namespace sonarqube \
		create secret \
		generic admin \
		--from-literal=sonarqube-password=${SONARQUBE_ADMIN_PASSWORD} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/bootstrap/manifests/sonarqube-admin-password.yaml
	kubectl apply -f ./devops-app/bootstrap/manifests/sonarqube-admin-password.yaml
	git add ./devops-app/bootstrap/manifests/sonarqube-admin-password.yaml
	git commit -m "Add SonarQube admin password secret"
	git push

# Bootstrap the devops-app
bootstrap:
	kustomize build ./devops-app/bootstrap | kubectl apply -f -

# Configure ArgoCD
argocd:
	ARGOCD_PASSWORD=$$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) && echo $$ARGOCD_PASSWORD
	kubectl port-forward -n argocd svc/argocd-server 8081:80 & echo $$! > /tmp/port-forward.pid & sleep 5
	argocd login localhost:8081 --insecure --grpc-web --username admin --password $$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
	argocd account update-password --current-password $$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) --new-password $(ARGOCD_PASSWORD)
	kill $$(cat /tmp/port-forward.pid) && rm -f /tmp/port-forward.pid

all: cluster_local initial_setup add_repo ca minio sonarqube bootstrap argocd

# Destroy the local Kubernetes cluster
destroy:
	kind delete cluster --name local 
