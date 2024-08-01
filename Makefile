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
cluster-create:
	@echo "Creating local Kubernetes cluster"
	kind create cluster --config ./kind/cluster-local.yaml

initial-argocd-setup:
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm upgrade --install \
		argocd argo/argo-cd \
		--namespace argocd \
		--create-namespace \
		--wait
	kubectl apply -f devops-app/argo-cd/projects

sealed-secrets:
	kustomize build ./devops-app/sealed-secrets | kubectl apply -f -
	sleep 60

# Configure the ArgoCD repository
add-repo:
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
	--local -oyaml > ./devops-app/devops-app/repo-devops-toys.yaml
	git add ./devops-app/devops-app/repo-devops-toys.yaml
	git commit -m "Add devops-toys repo to Argocd"
	git push

cert-manager:
	kubectl create namespace cert-manager
	openssl genrsa -out ca.key 4096
	openssl req -new -x509 -sha256 -days 3650 \
		-key ca.key \
		-out ca.crt \
		-subj '/CN=$(CN)/emailAddress=$(GITHUB_EMAIL)/C=$(C)/ST=$(ST)/L=$(L)/O=$(O)/OU=$(OU)'
	kubectl --namespace cert-manager \
		create secret \
		generic devops-local-ca \
		--from-file=tls.key=ca.key \
		--from-file=tls.crt=ca.crt \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets -oyaml - | \
		kubectl patch -f - \
		-p '{"spec": {"template": {"metadata": {"annotations": {"argocd.argoproj.io/sync-wave":"1"}}}}}' \
		--dry-run=client \
		--type=merge \
		--local -oyaml > ./devops-app/cert-manager-config/local/ca-secret.yaml
	git add ./devops-app/cert-manager-config/local/ca-secret.yaml
	git commit -m "Add CA cert secret"
	git push
	sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
	kustomize build ./devops-app/cert-manager | kubectl apply -f -
	kustomize build ./devops-app/cert-manager-config | kubectl apply -f -
	sleep 60

kube-prometheus-stack:
	kustomize build ./devops-app/kube-prometheus-stack | kubectl apply -f -
	sleep 60

ingress-nginx:
	kustomize build ./devops-app/ingress-nginx | kubectl apply -f -
	sleep 60

trust-manager:
	kustomize build ./devops-app/trust-manager | kubectl apply -f -

minio:
	kubectl create namespace minio
	# Create minio users
	@./scripts/minio_users.sh "${MINIO_USERNAME}" "${MINIO_PASSWORD}"
	kubectl apply -f ./devops-app/minio-config/local/minio-users-secret.yaml
	git add ./devops-app/minio-config/local/minio-users-secret.yaml
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
		tee ./devops-app/minio-config/local/minio-root-secret.yaml
	kubectl apply -f ./devops-app/minio-config/local/minio-root-secret.yaml
	git add ./devops-app/minio-config/local/minio-root-secret.yaml
	git commit -m "Add MinIO root credentials"
	git push
	kustomize build ./devops-app/minio | kubectl apply -f -
	kustomize build ./devops-app/minio-config | kubectl apply -f -
	sleep 60

grafana-mimir:
	kubectl create namespace mimir
	kubectl --namespace mimir \
		create secret \
		generic minio-creds \
		--from-literal=accesskey=${MINIO_USERNAME} \
		--from-literal=secretkey=${MINIO_PASSWORD} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/grafana-mimir-config/local/storage-credentials.yaml
	kubectl apply -f ./devops-app/grafana-mimir-config/local/storage-credentials.yaml
	git add ./devops-app/grafana-mimir-config/local/storage-credentials.yaml
	git commit -m "Add storage credentials"
	git push
	kustomize build ./devops-app/grafana-mimir | kubectl apply -f -
	kustomize build ./devops-app/grafana-mimir-config | kubectl apply -f -
	sleep 60

grafana-loki:
	kubectl create namespace loki
	htpasswd -b -c .htpasswd ${LOKI_USER} ${LOKI_PASSWORD}
	htpasswd -b .htpasswd ${LOKI_USER_LOCAL} ${LOKI_PASSWORD_LOCAL}
	kubectl -n loki create secret generic loki-gateway-auth --from-file=.htpasswd --dry-run=client -o yaml > htaccess-loki.yaml
	kubeseal --format yaml --controller-name=sealed-secrets --controller-namespace=sealed-secrets < htaccess-loki.yaml > ./devops-app/grafana-loki-config/local/htaccess-loki.yaml
	kubectl apply -f ./devops-app/grafana-loki-config/local/htaccess-loki.yaml
	git add ./devops-app/grafana-loki-config/local/htaccess-loki.yaml
	git commit -m "Add Loki gateway auth"
	kubectl --namespace loki \
		create secret \
		generic minio-creds \
		--from-literal=accesskey=${MINIO_USERNAME} \
		--from-literal=secretkey=${MINIO_PASSWORD} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/grafana-loki-config/local/storage-credentials.yaml
	kubectl apply -f ./devops-app/grafana-loki-config/local/storage-credentials.yaml
	git add ./devops-app/grafana-loki-config/local/storage-credentials.yaml
	git commit -m "Add storage credentials"
	git push
	git push
	kustomize build ./devops-app/grafana-loki-config | kubectl apply -f -
	kustomize build ./devops-app/grafana-loki | kubectl apply -f -
	sleep 60

grafana-promtail:
	kubectl create namespace promtail
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
		tee ./devops-app/grafana-promtail-config/local/promtail-credentials.yaml
	kubectl apply -f ./devops-app/grafana-promtail-config/local/promtail-credentials.yaml
	git add ./devops-app/grafana-promtail-config/local/promtail-credentials.yaml
	git commit -m "Add promtail credentials"
	git push
	kustomize build ./devops-app/grafana-promtail-config | kubectl apply -f -
	kustomize build ./devops-app/grafana-promtail | kubectl apply -f -

argo-workflows:
	kubectl create namespace argo
	kubectl --namespace argo \
		create secret \
		generic minio-creds \
		--from-literal=accesskey=${MINIO_USERNAME} \
		--from-literal=secretkey=${MINIO_PASSWORD} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/argo-workflows-config/local/storage-credentials.yaml
	kubectl apply -f ./devops-app/argo-workflows-config/local/storage-credentials.yaml
	git add ./devops-app/argo-workflows-config/local/storage-credentials.yaml
	git commit -m "Add storage credentials"
	git push
	kustomize build ./devops-app/argo-workflows | kubectl apply -f -
	kustomize build ./devops-app/argo-workflows-config | kubectl apply -f -
	sleep 60

metallb:
	kustomize build ./devops-app/metallb | kubectl apply -f -
	kustomize build ./devops-app/metallb-config | kubectl apply -f -

configure-argocd:
	ARGOCD_PASSWORD=$$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) && echo $$ARGOCD_PASSWORD
	kubectl port-forward -n argocd svc/argocd-server 8081:80 & echo $$! > /tmp/port-forward.pid & sleep 5
	argocd login localhost:8081 --insecure --grpc-web --username admin --password $$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
	argocd account update-password --current-password $$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) --new-password $(ARGOCD_PASSWORD)
	kill $$(cat /tmp/port-forward.pid) && rm -f /tmp/port-forward.pid

configure-repo:
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
	--local -oyaml > ./devops-app/devops-app/repo-devops-toys.yaml
	kubectl apply -f ./devops-app/devops-app/repo-devops-toys.yaml
	git add ./devops-app/devops-app/repo-devops-toys.yaml
	git commit -m "Add devops-toys repo to Argocd"
	git push

opentelemetry-operator:
	kustomize build ./devops-app/opentelemetry-operator | kubectl apply -f -

grafana:
	kubectl create namespace grafana
	kubectl --namespace grafana \
		create secret \
		generic grafana-admin \
		--from-literal=GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER} \
		--from-literal=GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/grafana-config/local/grafana-admin.yaml
	kubectl apply -f ./devops-app/grafana-config/local/grafana-admin.yaml
	git add ./devops-app/grafana-config/local/grafana-admin.yaml
	git commit -m "Add grafana admin secret"
	kubectl --namespace grafana \
		create secret \
		generic grafana-loki-tenants \
		--from-literal=LOKI_TENANT_1_ID=${LOKI_TENANT_1_ID} \
		--from-literal=LOKI_TENANT_2_ID=${LOKI_TENANT_2_ID} \
		--output json \
		--dry-run=client | \
		kubeseal --format yaml \
		--controller-name=sealed-secrets \
		--controller-namespace=sealed-secrets | \
		tee ./devops-app/grafana-config/local/grafana-loki-tenants.yaml
	kubectl apply -f ./devops-app/grafana-config/local/grafana-loki-tenants.yaml
	git add ./devops-app/grafana-config/local/grafana-loki-tenants.yaml
	git commit -m "Add grafana loki tenants secret"
	git push
	kustomize build ./devops-app/grafana-config | kubectl apply -f -
	kustomize build ./devops-app/grafana | kubectl apply -f -

devops-app-1:
	kustomize build ./devops-app/devops-app/| kubectl apply -f -

all: cluster-create initial-argocd-setup sealed-secrets cert-manager kube-prometheus-stack ingress-nginx minio grafana grafana-mimir grafana-loki grafana-promtail metallb configure-argocd configure-repo trust-manager opentelemetry-operator argo-workflows devops-app-1

# # Set the proper domain name
# domain_name:
# 	find devops-app -type f -name "*.yaml" -exec sed -i 's/devops.toys/$(DOMAIN_NAME)/g' {} \;
# 	git add .
# 	git commit -m "Change domain name"
# 	git push



# opentelemetry:
# 	kustomize build ./devops-app/opentelemetry-operator | kubectl apply -f -

# sonarqube: sonarqube_psql_backup sonarqube_credentials

# # Create a SonarQube PostgreSQL backup secret
# sonarqube_psql_backup:
# 	kubectl --namespace sonarqube \
# 		create secret \
# 		generic minio-creds \
# 		--from-literal=accesskey=${MINIO_USERNAME} \
# 		--from-literal=secretkey=${MINIO_PASSWORD} \
# 		--output json \
# 		--dry-run=client | \
# 		kubeseal --format yaml \
# 		--controller-name=sealed-secrets \
# 		--controller-namespace=sealed-secrets | \
# 		tee ./devops-app/bootstrap/manifests/sonarqube-psql-backup.yaml
# 	kubectl apply -f ./devops-app/bootstrap/manifests/sonarqube-psql-backup.yaml
# 	git add ./devops-app/bootstrap/manifests/sonarqube-psql-backup.yaml
# 	git commit -m "Add SonarQube PostgreSQL backup credentials"
# 	git push

# # Create a SonarQube admin password secret
# sonarqube_credentials:
# 	kubectl --namespace sonarqube \
# 		create secret \
# 		generic admin \
# 		--from-literal=sonarqube-password=${SONARQUBE_ADMIN_PASSWORD} \
# 		--output json \
# 		--dry-run=client | \
# 		kubeseal --format yaml \
# 		--controller-name=sealed-secrets \
# 		--controller-namespace=sealed-secrets | \
# 		tee ./devops-app/bootstrap/manifests/sonarqube-admin-password.yaml
# 	kubectl apply -f ./devops-app/bootstrap/manifests/sonarqube-admin-password.yaml
# 	git add ./devops-app/bootstrap/manifests/sonarqube-admin-password.yaml
# 	git commit -m "Add SonarQube admin password secret"
# 	git push

# Destroy the local Kubernetes cluster
destroy:
	kind delete cluster --name devops-toys
