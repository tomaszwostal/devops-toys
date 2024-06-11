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
cluster:
	@echo "Creating local Kubernetes cluster"
	kind create cluster --config ./kind/cluster-local.yaml

# Set the proper domain name
domain_name:
	find devops-app -type f -name "*.yaml" -exec sed -i 's/devops.toys/$(DOMAIN_NAME)/g' {} \;
	git add .
	git commit -m "Change domain name"
	git push

# Configure the local Kubernetes cluster
namespaces:
	kubectl create namespace minio
	kubectl create namespace metallb-system
	kubectl create namespace ingress-nginx
	kubectl create namespace monitoring
	kubectl create namespace cert-manager
initial_setup:
	# Install ArgoCD
	helm repo add argo https://argoproj.github.io/argo-helm
	helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait
	# Create basic projects in ArgoCD
	kubectl apply -f devops-app/argocd-project-cicd.yaml
	kubectl apply -f devops-app/argocd-project-core.yaml
	kubectl apply -f devops-app/argocd-project-monitoring.yaml
	kubectl apply -f devops-app/argocd-project-observability.yaml
	# # Install Prometheus
	kustomize build ./devops-app/kube-prometheus-stack | kubectl apply -f -
	kustomize build ./devops-app/sealed-secrets | kubectl apply -f -
	# # Install cert-manager
	kustomize build ./devops-app/cert-manager | kubectl apply -f -
	# # Install Opentelemetry Operator
	# 
	# kubectl create namespace opentelemetry
	# kustomize build ./devops-app/opentelemetry-operator | kubectl apply -f -
	# # Install Grafana
	# kubectl create namespace grafana
	# kustomize build ./devops-app/grafana | kubectl apply -f -
	
	# kustomize build ./devops-app/devops-app | kubectl apply -f -
	
	# kubectl create namespace sonarqube
	# kubectl create namespace argo
	kustomize build ./devops-app/ingress-nginx | kubectl apply -f -
	kustomize build ./devops-app/cert-manager | kubectl apply -f -
	kustomize build ./devops-app/metallb | kubectl apply -f -
	# kustomize build ./devops-app/trust-manager | kubectl apply -f -
	# kustomize build ./devops-app/cnpg | kubectl apply -f -
	# # TODO: Find a better solution - wait for cert-manager
	# sleep 180

sealed_secrets:
	kustomize build ./devops-app/sealed-secrets | kubectl apply -f -

metallb:
	kustomize build ./devops-app/metallb | kubectl apply -f -

opentelemetry:
	kustomize build ./devops-app/opentelemetry-operator | kubectl apply -f -

cert_manager:
	#kubectl create namespace cert-manager
	# Generata CA key
	openssl genrsa -out ca.key 4096
	# Generate CA cert
	openssl req -new -x509 -sha256 -days 3650 \
		-key ca.key \
		-out ca.crt \
		-subj '/CN=$(CN)/emailAddress=$(GITHUB_EMAIL)/C=$(C)/ST=$(ST)/L=$(L)/O=$(O)/OU=$(OU)'
	# Create secret with CA
	kubectl --namespace cert-manager \
		create secret \
		generic devops-local-ca \
		--from-file=tls.key=ca.key \
		--from-file=tls.crt=ca.crt \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee devops-app/cert-manager/ca-secret.yaml
			kubectl apply -f ./devops-app/cert-manager/ca-secret.yaml
			git add ./devops-app/cert-manager/ca-secret.yaml
			git commit -m "Add CA cert secret"
			git push
	# Make ca-cert trusted
	# For Arch Linux
	# sudo cp ca.crt /etc/ca-certificates/trust-source/anchors
	# sudo update-ca-trust
	# For Debian/Ubuntu
	#sudo cp ca.crt /usr/local/share/ca-certificates
	#sudo update-ca-certificates
	# For MacOS
	sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
	kustomize build ./devops-app/cert-manager | kubectl apply -f -

ingress_nginx:
	kustomize build ./devops-app/ingress-nginx | kubectl apply -f -

minio:
	# Create minio users
	@./scripts/minio_users.sh "${MINIO_USERNAME}" "${MINIO_PASSWORD}"
	kubectl apply -f ./devops-app/minio/minio-users-secret.yaml
	git add ./devops-app/minio/minio-users-secret.yaml
	git commit -m "Add MinIO users secret"
	git push
	# Create root minio root user
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
		tee ./devops-app/minio/minio-root-secret.yaml
	kubectl apply -f ./devops-app/minio/minio-root-secret.yaml
	git add ./devops-app/minio/minio-root-secret.yaml
	git commit -m "Add MinIO root credentials"
	git push
	kustomize build ./devops-app/minio | kubectl apply -f -

grafana_mimir:
	#kubectl create namespace mimir
	kubectl --namespace mimir \
		create secret \
		generic minio-creds \
		--from-literal=accesskey=${MINIO_ACCESS_KEY} \
		--from-literal=secretkey=${MINIO_SECRET_KEY} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/grafana-mimir/storage-credentials.yaml
	kubectl apply -f ./devops-app/grafana-mimir/storage-credentials.yaml
	git add ./devops-app/grafana-mimir/storage-credentials.yaml
	git commit -m "Add storage credentials"
	git push
	kustomize build ./devops-app/grafana-mimir | kubectl apply -f -

kube-prometheus-stack:
	kustomize build ./devops-app/kube-prometheus-stack | kubectl apply -f -

grafana:
	kubectl --namespace grafana \
		create secret \
		generic grafana-credentials \
		--from-literal=LOKI_TENANT_1_ID=${LOKI_TENANT_1_ID} \
		--from-literal=LOKI_TENANT_2_ID=${LOKI_TENANT_2_ID} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/grafana/grafana-credentials.yaml
	kubectl apply -f ./devops-app/grafana/grafana-credentials.yaml
	kustomize build ./devops-app/grafana | kubectl apply -f -

grafana_loki:
	htpasswd -b -c .htpasswd ${LOKI_USER} ${LOKI_PASSWORD}
	htpasswd -b .htpasswd ${LOKI_USER_LOCAL} ${LOKI_PASSWORD_LOCAL}
	kubectl -n loki create secret generic loki-gateway-auth --from-file=.htpasswd --dry-run=client -o yaml > htaccess-loki.yaml
	kubeseal --format yaml --controller-name=sealed-secrets --controller-namespace=sealed-secrets < htaccess-loki.yaml > ./devops-app/grafana-loki/htaccess-loki.yaml
	kustomize build ./devops-app/grafana-loki | kubectl apply -f -

grafana_promtail:
	kubectl --namespace promtail \
		create secret \
		generic promtail-credentials \
		--from-literal=username=${LOKI_USER} \
		--from-literal=password=${LOKI_PASSWORD} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/grafana-promtail/promtail-credentials.yaml
	kubectl apply -f ./devops-app/grafana-promtail/promtail-credentials.yaml
	git add ./devops-app/grafana-promtail/promtail-credentials.yaml
	git commit -m "Add promtail credentials"
	git push
	kustomize build ./devops-app/grafana-promtail | kubectl apply -f -

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


# Create minio secret for Argo Workflows
workflows_minio_argo:
	kubectl --namespace argo \
		create secret \
		generic minio \
		--from-literal=accesskey=${MINIO_ACCESS_KEY} \
		--from-literal=secretkey=${MINIO_SECRET_KEY} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/bootstrap/manifests/argo-minio-secret-argo.yaml
	kubectl apply -f ./devops-app/bootstrap/manifests/argo-minio-secret-argo.yaml
	git add ./devops-app/bootstrap/manifests/argo-minio-secret-argo.yaml
	git commit -m "Add MinIO secret for Argo Workflows in argo namespace"
	git push

# Create minio secret for Argo Workflows
workflows_minio_workflows:
	kubectl --namespace workflows \
		create secret \
		generic minio \
		--from-literal=accesskey=${MINIO_ACCESS_KEY} \
		--from-literal=secretkey=${MINIO_SECRET_KEY} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/bootstrap/manifests/argo-minio-secret-workflows.yaml
	kubectl apply -f ./devops-app/bootstrap/manifests/argo-minio-secret-workflows.yaml
	git add ./devops-app/bootstrap/manifests/argo-minio-secret-workflows.yaml
	git commit -m "Add MinIO secret for Argo Workflows in workflows namespace"
	git push

workflows_minio: workflows_minio_argo workflows_minio_workflows


all: cluster_local initial_setup add_repo ca minio sonarqube bootstrap argocd workflows_minio
# Destroy the local Kubernetes cluster
destroy:
	kind delete cluster --name devops-toys
