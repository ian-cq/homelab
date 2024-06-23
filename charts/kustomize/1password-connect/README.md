helm install connect 1password/connect --set-file connect.credentials=./1password-credentials.json --set operator.create=true --set operator.token.value=$OP_API_TOKEN --kubeconfig /etc/rancher/k3s/k3s.yaml

kubectl apply -f onepassworditems.onepassword.com.yaml 
