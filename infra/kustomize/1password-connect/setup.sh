#! /bin/bash

helm repo add 1password https://1password.github.io/connect-helm-charts/

helm repo update

op read op://quanianitis.com/1password-credentials/1password-credentials.json > /tmp/1password-credentials.json

helm install connect 1password/connect --set-file connect.credentials=/tmp/1password-credentials.json

rm /tmp/1password-credentials.json

kubectl create secret generic 1password \
    --from-literal=secret=$(op read op://quanianitis.com/1password-server-token/token) \
    --namespace external-secrets
