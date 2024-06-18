#!/bin/bash

# Pobieranie zmiennych środowiskowych
USERNAME=$1
PASSWORD=$2

# Przygotowanie danych do sekretu
cat <<EOF >./temp_user_config.txt
username=${USERNAME}
password=${PASSWORD}
disabled=false
policies=readwrite,consoleAdmin,diagnostics
setPolicies=false
EOF

# Tworzenie sekretu w Kubernetes
kubectl --namespace minio create secret generic centralized-minio-users \
--from-file=username1=./temp_user_config.txt \
--output json \
--dry-run=client | kubeseal --format yaml \
--controller-name=sealed-secrets \
--controller-namespace=sealed-secrets | tee ./devops-app/minio-config/local/minio-users-secret.yaml

# Usuwanie pliku tymczasowego
rm -f ./temp_user_config.txt