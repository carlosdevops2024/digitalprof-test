# flask-devops-demo 

Pipeline CI/CD completo con Azure DevOps, Docker, AWS ECR y despliegue en EKS con Helm.

---

## Arquitectura general

```
Azure DevOps Pipeline
│
├── Stage 1 - SonarCloud       → Análisis de calidad de código
├── Stage 2 - Sonar Result     → Reporte del Quality Gate
├── Stage 3 - Build & Push     → Docker build + push a AWS ECR
├── Stage 4 - Parallel Jobs    → Scripts paralelos en un solo agente
└── Stage 5 - Deploy EKS       → Helm upgrade/install en EKS
```

---

## Prerrequisitos

### Herramientas locales
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Terraform](https://developer.hashicorp.com/terraform/install)

### Servicios AWS necesarios
- Cuenta AWS con permisos de administrador
- ECR Registry creado: `flask-devops-demo`
- Clúster EKS: `flask-eks-cluster`
- IAM Role para el nodo group con policy del ALB Controller

---

## Variables del pipeline (Azure DevOps)

Configurar en **Library → Variable Group** llamado `flask-devops-secrets`:

| Variable | Descripción |
|---|---|
| `AWS_ACCOUNT_ID` | ID de la cuenta AWS (ej: `458329143948`) |
| `AWS_ACCESS_KEY_ID` | Access key de IAM con permisos ECR + EKS |
| `AWS_SECRET_ACCESS_KEY` | Secret key correspondiente |

---

## Infraestructura con Terraform

```bash
cd terraform/
terraform init
terraform apply
```

### Configuración del node group (`eks.tf`)

```hcl
eks_managed_node_groups = {
  default = {
    min_size       = 1
    max_size       = 3
    desired_size   = 3          # mínimo 3 con t3.micro
    instance_types = ["t3.micro"]
  }
}
```

>  Con `t3.micro` el límite es **4 pods por nodo**. Con 3 nodos tienes capacidad para ~12 pods en total. Si necesitas más capacidad usa `t3.medium` (17 pods/nodo).

### Escalar nodos manualmente (sin Terraform)

```bash
aws eks update-nodegroup-config \
  --cluster-name flask-eks-cluster \
  --nodegroup-name <nombre-del-nodegroup> \
  --scaling-config minSize=1,maxSize=3,desiredSize=3
```

Para obtener el nombre del nodegroup:
```bash
aws eks list-nodegroups --cluster-name flask-eks-cluster
```

---

## Instalación del ALB Controller (una sola vez, local)

El AWS Load Balancer Controller es necesario para que el Ingress cree un ALB en AWS.

### 1. Agregar permisos IAM al rol del nodo

```bash
# Descargar la policy oficial
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

# Crear la policy en AWS
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Adjuntar al rol del nodo (reemplazar con el nombre real del rol)
aws iam attach-role-policy \
  --role-name <nombre-del-rol-del-nodo> \
  --policy-arn arn:aws:iam::<AWS_ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy
```

### 2. Instalar el controller con Helm

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=flask-eks-cluster \
  --set serviceAccount.create=true \
  --set region=us-east-1
```

### 3. Verificar que está corriendo

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

Debe mostrar `1/1 Running` en todos los pods.

---

## Helm Chart (`helm/flask-app`)

### values.yaml

```yaml
replicaCount: 2

image:
  repository: <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/flask-devops-demo
  tag: latest
  pullPolicy: Always

service:
  type: ClusterIP
  port: 80
  targetPort: 5000

ingress:
  enabled: true
  className: alb
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip

resources:
  requests:
    memory: "64Mi"
    cpu: "100m"
  limits:
    memory: "128Mi"
    cpu: "250m"
```

### Deploy manual

```bash
helm upgrade --install flask-app ./helm/flask-app \
  --namespace flask-app \
  --create-namespace \
  --set image.repository=<ECR_REGISTRY>/flask-devops-demo \
  --set image.tag=<IMAGE_TAG> \
  --wait \
  --timeout 5m
```

---

## Verificar el despliegue

### Estado general

```bash
# Pods
kubectl get pods -n flask-app

# Servicio
kubectl get svc -n flask-app

# Ingress (URL pública)
kubectl get ingress -n flask-app --watch
```

Cuando el Ingress tenga ADDRESS, esa es la URL pública:
```
NAME            CLASS   HOSTS   ADDRESS                                          PORTS
flask-ingress   alb     *       k8s-flaskapp-xxxx.us-east-1.elb.amazonaws.com   80
```

### Logs de la aplicación

```bash
kubectl logs -n flask-app -l app=flask-app --tail=50
```

### Eventos del namespace (para diagnosticar problemas)

```bash
kubectl get events -n flask-app --sort-by='.lastTimestamp'
```

---

## Solución de problemas comunes

### Pods en estado `Pending`
```
0/2 nodes are available: 2 Too many pods.
```
**Causa:** nodos llenos (límite de pods por instancia alcanzado).  
**Solución:** aumentar `desired_size` a 3 nodos en Terraform o via AWS CLI.

---

### Ingress sin ADDRESS
```
flask-ingress   alb   *   <none>   80
```
**Causa:** ALB Controller sin permisos IAM o `ingressClassName` no configurado.  
**Solución:**
1. Verificar logs del controller: `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50`
2. Adjuntar la IAM policy al rol del nodo (ver sección de instalación del ALB Controller)
3. Parchear el Ingress si `CLASS` es `<none>`:
```bash
kubectl patch ingress flask-ingress -n flask-app \
  --type merge -p '{"spec":{"ingressClassName":"alb"}}'
```

---

### AccessDenied en logs del ALB Controller
```
AccessDenied: elasticloadbalancing:DescribeLoadBalancers
```
**Causa:** el rol del nodo EC2 no tiene la policy del ALB Controller.  
**Solución:** seguir los pasos de la sección **Instalación del ALB Controller → Paso 1**.

---

### Helm no encontrado en el agente de Azure DevOps
```
helm : El término 'helm' no se reconoce...
```
**Causa:** `winget` instala Helm pero no refresca el PATH en la sesión actual.  
**Solución:** el pipeline descarga el binario directamente a `C:\Windows\System32` (ya incluido en el `azure-pipelines.yml`).

---

## Estructura del proyecto

```
digitalprof-test/
├── app/
│   ├── app.py
│   └── requirements.txt
├── helm/
│   └── flask-app/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           └── ingress.yaml
├── terraform/
│   ├── main.tf
│   ├── eks.tf
│   ├── vpc.tf
│   └── variables.tf
├── Dockerfile
├── azure-pipelines.yml
└── README.md
```