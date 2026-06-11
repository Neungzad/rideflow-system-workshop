# RideFlow — Copilot CLI Project Context

## Project Overview

Real-time food delivery & transport platform (Grab/Lineman style).
Built as a microservice learning workshop targeting production-level engineering interviews in Thailand.
The developer has hands-on experience with roadside dispatch systems — this informs the driver matching design.

## Architecture Rules (NEVER violate these)

1. All inter-service communication is async via Kafka — NO direct HTTP calls between internal services
2. Database per service — NO service reads another service's database
3. API Gateway is the ONLY entry point for external HTTP traffic
4. Every Kafka consumer must be idempotent (reprocessing a message must not create duplicates)
5. Every service must expose GET /health
6. All secrets via K8s Secrets — never hardcoded
7. All config via ConfigMap: rideflow-config

## Tech Stack

### Go Services

- Router: chi (github.com/go-chi/chi/v5)
- PostgreSQL: pgx/v5 (github.com/jackc/pgx/v5)
- Kafka: Sarama (github.com/IBM/sarama)
- JWT: golang-jwt/jwt/v5
- Migrations: golang-migrate
- Logging: slog (standard library, structured JSON)

### Node.js Services

- Runtime: Node.js 20 LTS
- Framework: Express
- Kafka: kafkajs
- RabbitMQ: amqplib
- PostgreSQL: pg (node-postgres)
- Logging: pino

## Service Port Map

- api-gateway: 8080
- user-service: 8001
- order-service: 8002
- merchant-service: 8003
- matching-service: 8004
- location-service: 8005
- notification-service: 8006
- payment-service: 8007
- rating-service: 8008

## Kafka Config

- Brokers: rideflow-kafka-kafka-bootstrap.rideflow.svc.cluster.local:9092
- Consumer group naming: {service-name}-cg (e.g. matching-service-cg)
- All topics listed in SPEC.md → Kafka Topic Specification
- Partition key for driver.location: driver_id (ensures ordering per driver)
- Partition key for order topics: order_id

## Kubernetes

- Namespace: rideflow
- All deployments use resource limits (see SPEC.md)
- ConfigMap name: rideflow-config
- Secret naming: {service-name}-secrets

## File Structure per Go Service

```
services/{service-name}/
├── cmd/
│   └── main.go
├── internal/
│   ├── handler/       ← HTTP handlers
│   ├── repository/    ← DB queries
│   ├── service/       ← Business logic
│   ├── middleware/    ← JWT, logging, etc.
│   ├── model/         ← Structs / domain types
│   └── kafka/         ← Producer / Consumer
├── migrations/        ← SQL migration files
├── Dockerfile
└── go.mod
```

## File Structure per Node.js Service

```
services/{service-name}/
├── src/
│   ├── routes/
│   ├── controllers/
│   ├── services/
│   ├── middleware/
│   ├── kafka/
│   └── rabbitmq/
├── Dockerfile
└── package.json
```

## Current Phase

Phase 1 — Foundation: Minikube + Kafka (Strimzi) + Redis + PostgreSQL + RabbitMQ setup

## Reference

Full spec, data models, API contracts, Kafka schemas, K8s manifests: see SPEC.md
Learning workflow and Copilot CLI prompt guide: see LEARNING_WORKFLOW.md
