#!/usr/bin/env bash
# setup-minikube.sh — Phase 1 Foundation Setup
# Starts Minikube + deploys: Kafka (Strimzi), Redis, RabbitMQ, PostgreSQL (x5)
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Prerequisites ────────────────────────────────────────────────────────────
for cmd in minikube kubectl helm; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is not installed. Please install it first."
done

NAMESPACE="rideflow"
STRIMZI_VERSION="0.40.0"

# ─── Step 1: Start Minikube ───────────────────────────────────────────────────
info "Step 1/7 — Starting Minikube (4 CPU, 7.8GB RAM)..."
if minikube status &>/dev/null; then
  warn "Minikube is already running — skipping start."
else
  minikube start \
    --cpus=4 \
    --memory=7800 \
    --driver=docker \
    --addons=ingress,metrics-server  # OrbStack uses docker driver
fi

info "Waiting for Minikube node to be Ready..."
kubectl wait node --all --for=condition=Ready --timeout=120s
success "Minikube is up."

# ─── Step 2: Create namespace ────────────────────────────────────────────────
info "Step 2/7 — Creating namespace '${NAMESPACE}'..."
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"
success "Namespace '${NAMESPACE}' ready."

# ─── Step 3: Install Strimzi Operator ────────────────────────────────────────
info "Step 3/7 — Installing Strimzi Operator v${STRIMZI_VERSION}..."
kubectl apply -f \
  "https://strimzi.io/install/latest?namespace=${NAMESPACE}" \
  -n "$NAMESPACE"

info "Waiting for Strimzi Operator to be ready..."
kubectl rollout status deployment/strimzi-cluster-operator \
  -n "$NAMESPACE" --timeout=180s

info "Waiting for Strimzi CRDs to be registered..."
kubectl wait --for=condition=Established crd/kafkas.kafka.strimzi.io --timeout=60s
kubectl wait --for=condition=Established crd/kafkatopics.kafka.strimzi.io --timeout=60s
success "Strimzi Operator is running."

# ─── Step 4: Deploy Kafka cluster (CRD) ──────────────────────────────────────
info "Step 4/7 — Applying Kafka cluster from k8s/kafka/kafka-cluster.yaml..."
kubectl apply -n "$NAMESPACE" -f k8s/kafka/kafka-cluster.yaml

info "Waiting for Kafka brokers to be ready (this may take 2-3 minutes)..."
kubectl wait kafka/rideflow-kafka \
  --for=condition=Ready \
  -n "$NAMESPACE" \
  --timeout=300s
success "Kafka cluster is ready."

# ─── Step 5: Create Kafka Topics ─────────────────────────────────────────────
info "Step 5/7 — Creating KafkaTopic CRDs from k8s/kafka/topics/..."
kubectl apply -n "$NAMESPACE" -f k8s/kafka/topics/

info "Waiting for all KafkaTopics to be Ready..."
kubectl wait kafkatopic --all \
  --for=condition=Ready \
  -n "$NAMESPACE" \
  --timeout=120s
success "All Kafka topics created."

# ─── Step 6: Helm repos ──────────────────────────────────────────────────────
info "Adding Helm repositories..."
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
helm repo update
success "Helm repos updated."

# ─── Step 7a: Redis ──────────────────────────────────────────────────────────
info "Step 6/7 — Installing Redis (standalone)..."
helm upgrade --install redis bitnami/redis \
  --namespace "$NAMESPACE" \
  --set architecture=standalone \
  --set auth.enabled=false \
  --set master.resources.requests.cpu=100m \
  --set master.resources.requests.memory=128Mi \
  --set master.resources.limits.cpu=200m \
  --set master.resources.limits.memory=256Mi \
  --wait --timeout=120s
success "Redis installed."

# ─── Step 7b: RabbitMQ ───────────────────────────────────────────────────────
# Using official rabbitmq image via kubectl — Bitnami images no longer on Docker Hub
info "Step 6/7 — Installing RabbitMQ (official image)..."
kubectl apply -n "$NAMESPACE" -f k8s/rabbitmq/rabbitmq.yaml

info "Waiting for RabbitMQ to be ready..."
kubectl rollout status statefulset/rabbitmq -n "$NAMESPACE" --timeout=180s
kubectl wait pod -l app=rabbitmq \
  --for=condition=Ready \
  -n "$NAMESPACE" \
  --timeout=180s
success "RabbitMQ installed."

# ─── Step 7c: PostgreSQL (one instance per service) ──────────────────────────
info "Step 7/7 — Installing PostgreSQL instances (5 services)..."

install_postgres() {
  local service="$1"
  local db_name="$2"

  info "  → postgres-${service} (db: ${db_name})"
  helm upgrade --install "postgres-${service}" bitnami/postgresql \
    --namespace "$NAMESPACE" \
    --set auth.database="$db_name" \
    --set auth.username="$service" \
    --set auth.password="${service}_dev_pass" \
    --set primary.resources.requests.cpu=100m \
    --set primary.resources.requests.memory=128Mi \
    --set primary.resources.limits.cpu=200m \
    --set primary.resources.limits.memory=256Mi \
    --set primary.persistence.enabled=false \
    --wait --timeout=180s
}

install_postgres "user"         "userdb"
install_postgres "order"        "orderdb"
install_postgres "merchant"     "merchantdb"
install_postgres "payment"      "paymentdb"
install_postgres "rating"       "ratingdb"

success "All PostgreSQL instances installed."

# ─── Apply shared ConfigMap ──────────────────────────────────────────────────
info "Applying shared ConfigMap (rideflow-config)..."
kubectl apply -n "$NAMESPACE" -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: rideflow-config
  namespace: rideflow
data:
  kafka_brokers: "rideflow-kafka-kafka-bootstrap.rideflow.svc.cluster.local:9092"
  rabbitmq_host: "rabbitmq.rideflow.svc.cluster.local"
  redis_host: "redis-master.rideflow.svc.cluster.local"
  environment: "development"
EOF
success "ConfigMap applied."

# ─── Final health summary ────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Phase 1 Foundation setup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "All pods in namespace '${NAMESPACE}':"
kubectl get pods -n "$NAMESPACE"
echo ""
echo -e "Kafka topics:"
kubectl get kafkatopics -n "$NAMESPACE"
echo ""
echo -e "${YELLOW}Next step:${NC} Run the smoke test:"
echo -e "  # Terminal 1 — Consumer (start first):"
echo -e "  kubectl run kafka-consumer --rm -it --restart=Never \\"
echo -e "    --image=quay.io/strimzi/kafka:1.0.0-kafka-4.2.0 \\"
echo -e "    -n rideflow \\"
echo -e "    -- bin/kafka-console-consumer.sh \\"
echo -e "       --bootstrap-server rideflow-kafka-kafka-bootstrap.rideflow.svc.cluster.local:9092 \\"
echo -e "       --topic order.created --from-beginning"
echo -e ""
echo -e "  # Terminal 2 — Producer:"
echo -e "  kubectl run kafka-producer --rm -it --restart=Never \\"
echo -e "    --image=quay.io/strimzi/kafka:1.0.0-kafka-4.2.0 \\"
echo -e "    -n rideflow \\"
echo -e "    -- bin/kafka-console-producer.sh \\"
echo -e "       --bootstrap-server rideflow-kafka-kafka-bootstrap.rideflow.svc.cluster.local:9092 \\"
echo -e "       --topic order.created"
