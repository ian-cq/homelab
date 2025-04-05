#! /bin/bash

helm repo add 1password https://1password.github.io/connect-helm-charts/

helm repo update

op read op://quanianitis.com/1password-credentials/1password-credentials.json > /tmp/1password-credentials.json

kubectl create ns 1password
kubectl create ns external-secrets

helm install connect 1password/connect -n 1password --set-file connect.credentials=/tmp/1password-credentials.json

rm /tmp/1password-credentials.json

kubectl create secret generic 1password \
    --from-literal=token=$(op read op://quanianitis.com/1password-server-token/token) \
    --namespace external-secrets
