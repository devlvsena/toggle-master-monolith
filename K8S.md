# Deploy no Kubernetes

Este guia descreve como executar o ToggleMaster no Kubernetes usando Minikube e PostgreSQL executado pelo Docker Compose na máquina host.

## Pré-requisitos

Instale e configure:

- Docker Desktop
- Minikube
- `kubectl`
- AWS CLI configurada com acesso ao Amazon ECR

Confirme as ferramentas:

```bash
docker --version
minikube version
kubectl version --client
aws sts get-caller-identity
```

## Arquitetura local

Neste cenário:

- A API roda em pods no Minikube.
- A imagem da API é armazenada no Amazon ECR.
- O PostgreSQL roda pelo Docker Compose na máquina host.
- O pod acessa o banco pela porta `5432` usando `host.docker.internal`.

O PostgreSQL precisa estar iniciado e publicar a porta para o host:

```bash
docker compose up -d db
docker compose ps
```

A saída deve indicar uma publicação semelhante a `0.0.0.0:5432->5432/tcp`.

## Iniciar o Minikube

```bash
minikube start
kubectl get nodes
```

O nó deve aparecer como `Ready`.

Habilite o servidor de métricas para que o HPA funcione:

```bash
minikube addons enable metrics-server
kubectl get pods -n kube-system | grep metrics
```

## Publicar a imagem no ECR

Defina o endereço da imagem:

```bash
export ECR_REGISTRY="180981210379.dkr.ecr.us-east-1.amazonaws.com"
export IMAGE="$ECR_REGISTRY/toggle-master-monolith:latest"
```

Faça login no ECR, construa a imagem e envie-a:

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker build -t "$IMAGE" .
docker push "$IMAGE"
```

Confirme que a tag existe:

```bash
aws ecr describe-images \
  --repository-name toggle-master-monolith \
  --region us-east-1 \
  --query 'imageDetails[].imageTags'
```

## Configurar acesso ao ECR no Minikube

O repositório ECR é privado. Crie um Secret no namespace da aplicação usando um token temporário do ECR:

```bash
ECR_PASSWORD="$(aws ecr get-login-password --region us-east-1)"

kubectl create secret docker-registry ecr-regcred \
  --namespace togglemaster \
  --docker-server="$ECR_REGISTRY" \
  --docker-username=AWS \
  --docker-password="$ECR_PASSWORD"
```

O Deployment referencia esse Secret em `spec.template.spec.imagePullSecrets`. O token do ECR expira normalmente após algumas horas; recrie o Secret quando necessário:

```bash
kubectl delete secret ecr-regcred -n togglemaster
ECR_PASSWORD="$(aws ecr get-login-password --region us-east-1)"
kubectl create secret docker-registry ecr-regcred \
  --namespace togglemaster \
  --docker-server="$ECR_REGISTRY" \
  --docker-username=AWS \
  --docker-password="$ECR_PASSWORD"
```

## Configurar o banco

O arquivo `k8s/togglemaster-configmap.yml` contém os valores não sensíveis:

```yaml
DB_HOST: host.docker.internal
DB_NAME: togglemaster
DB_PORT: "5432"
```

O arquivo `k8s/togglemaster-secret.yml` contém `DB_USER` e `DB_PASSWORD` em Base64. Para gerar valores corretamente:

```bash
echo -n 'user' | base64
echo -n 'password' | base64
```

Não use essas credenciais de exemplo em produção. Prefira criar o Secret fora do Git:

```bash
kubectl create secret generic togglemaster-secret \
  -n togglemaster \
  --from-literal=DB_USER='seu_usuario' \
  --from-literal=DB_PASSWORD='sua_senha' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Se o banco estiver em outro ambiente, substitua `DB_HOST` pelo hostname ou endpoint acessível pelos pods.

## Validar os manifests

No diretório raiz do projeto:

```bash
kubectl apply --dry-run=client -f k8s/
kubectl apply --dry-run=server -f k8s/
kubectl diff -f k8s/
```

O `--dry-run=server` exige um cluster acessível e valida os recursos contra a API do Kubernetes.

## Aplicar a aplicação

Aplique os recursos nesta ordem:

```bash
kubectl apply -f k8s/togglemaster-namespace.yml
kubectl apply -f k8s/togglemaster-configmap.yml
kubectl apply -f k8s/togglemaster-secret.yml
kubectl apply -f k8s/togglemaster-deployment.yml
kubectl apply -f k8s/togglemaster-service.yml
kubectl apply -f k8s/togglemaster-hpa.yml
```

Ou aplique todos os arquivos de uma vez:

```bash
kubectl apply -f k8s/
```

## Verificar o deploy

```bash
kubectl get all -n togglemaster
kubectl get configmap,secret,hpa -n togglemaster
kubectl get pods -n togglemaster -o wide
kubectl rollout status deployment/togglemaster-deployment -n togglemaster
```

O estado esperado dos pods é `1/1 Running`.

Confira se o Service encontrou os pods:

```bash
kubectl get svc togglemaster-service -n togglemaster
kubectl get endpoints togglemaster-service -n togglemaster
```

Se os endpoints estiverem vazios, verifique se o selector do Service (`app: togglemaster`) coincide com os labels do Deployment.

## Acessar a API

Como o Service é `NodePort`, obtenha uma URL acessível pelo host:

```bash
minikube service togglemaster-service -n togglemaster --url
```

Guarde a URL retornada, por exemplo `http://127.0.0.1:60378`, e teste:

```bash
export API_URL="http://127.0.0.1:60378"
curl -i "$API_URL/health"
curl -i "$API_URL/flags"
```

Alternativamente, use port-forward:

```bash
kubectl port-forward svc/togglemaster-service 5000:5000 -n togglemaster
```

Em outro terminal:

```bash
curl -i http://localhost:5000/health
```

Teste a API de flags:

```bash
curl -i -X POST "$API_URL/flags" \
  -H 'Content-Type: application/json' \
  -d '{"name":"feature-k8s","is_enabled":true}'

curl -i "$API_URL/flags/feature-k8s"

curl -i -X PUT "$API_URL/flags/feature-k8s" \
  -H 'Content-Type: application/json' \
  -d '{"is_enabled":false}'
```

## Validar o HPA

Confira se o Metrics Server fornece métricas:

```bash
kubectl top pods -n togglemaster
kubectl top nodes
kubectl get hpa -n togglemaster
```

O HPA está configurado para manter a CPU em 50% do request, com 2 a 5 réplicas.

Para gerar carga usando a URL do Service:

```bash
API_URL="http://127.0.0.1:60378"
DURATION=180
END=$((SECONDS + DURATION))

for i in $(seq 1 20); do
  (
    while [ "$SECONDS" -lt "$END" ]; do
      curl -s "$API_URL/health" > /dev/null
    done
  ) &
done

wait
```

Acompanhe o escalonamento em outro terminal:

```bash
kubectl get hpa -n togglemaster -w
kubectl get pods -n togglemaster -w
kubectl describe hpa togglemaster-hpa -n togglemaster
```

O HPA pode levar alguns ciclos para escalar. Após o fim da carga, a redução pode aguardar a janela padrão de estabilização, normalmente cerca de 5 minutos.

Para testes, reduza temporariamente essa janela para 60 segundos:

```bash
kubectl patch hpa togglemaster-hpa \
  -n togglemaster \
  --type=merge \
  -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":60}}}}'
```

## Diagnóstico

### Pod em `ImagePullBackOff` ou `ErrImagePull`

Verifique os eventos:

```bash
kubectl describe pod <pod> -n togglemaster
kubectl get events -n togglemaster --sort-by=.lastTimestamp
```

Se aparecer `no basic auth credentials`, recrie o Secret `ecr-regcred`. Confirme também a imagem e a tag no Deployment:

```bash
kubectl get deployment togglemaster-deployment -n togglemaster \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

### Pod em `CreateContainerError`

Veja a mensagem do runtime e confirme os Secrets:

```bash
kubectl get pod <pod> -n togglemaster \
  -o jsonpath='{.status.containerStatuses[0].state.waiting.message}{"\n"}'

kubectl get secret ecr-regcred togglemaster-secret -n togglemaster
```

Valores colocados em `data` precisam estar em Base64. Alternativamente, use `stringData` em um arquivo local não versionado.

### Pod em `CrashLoopBackOff`

Consulte os logs atual e anterior:

```bash
kubectl logs <pod> -n togglemaster
kubectl logs <pod> -n togglemaster --previous
```

Confirme as variáveis sem imprimir senhas:

```bash
kubectl exec -n togglemaster <pod> -- printenv | grep '^DB_'
```

A imagem usa `entrypoint.sh`, que exige `DB_HOST`, `DB_PORT` e `DB_NAME`, aguarda o PostgreSQL com `pg_isready` e inicializa a tabela `flags` antes de iniciar o Gunicorn.

### HPA sem métricas

Se `kubectl top` falhar ou o HPA informar `no metrics returned from resource metrics API`:

```bash
minikube addons enable metrics-server
kubectl get pods -n kube-system | grep metrics
kubectl top pods -n togglemaster
```

## Atualizar a aplicação

Depois de publicar uma nova imagem com a mesma tag `latest`, reinicie o Deployment:

```bash
kubectl rollout restart deployment/togglemaster-deployment -n togglemaster
kubectl rollout status deployment/togglemaster-deployment -n togglemaster
```

Para acompanhar logs:

```bash
kubectl logs deployment/togglemaster-deployment -n togglemaster --tail=100 -f
```

Em ambientes reais, prefira tags imutáveis, como `:v1.0.1`, em vez de reutilizar `:latest`.

## Remover os recursos

```bash
kubectl delete -f k8s/
```

Para parar o Minikube:

```bash
minikube stop
```
