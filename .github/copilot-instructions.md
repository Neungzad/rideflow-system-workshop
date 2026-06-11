# RideFlow Project Context

## Project
Real-time food delivery & transport platform (Grab/Lineman style).
Built as a microservice learning workshop for production-level engineering interviews.

## Architecture
- 9 microservices communicating via Kafka (primary) and HTTP (gateway only)
- Kubernetes orchestration (Minikube for local, EKS for AWS)
- Kafka via Strimzi Operator for on-premise
- RabbitMQ for async task queues (on-prem) / SNS+SQS on AWS
- Database per service pattern (PostgreSQL per service, Redis for location/matching)

## Tech Stack
- Go services: api-gateway (Node.js), user-service, order-service,
  matching-service, location-service, payment-service
- Node.js services: merchant-service, notification-service, rating-service,
  email-worker, sms-worker, rating-reminder-worker
- Kafka topics: see SPEC.md → Kafka Topic Specification
- All inter-service communication is async via Kafka. No direct HTTP between services.

## Coding Standards
- Go: use standard library + chi router + pgx for postgres + sarama for Kafka
- Node.js: use Express + kafkajs + amqplib for RabbitMQ
- Every service must expose GET /health endpoint
- All errors logged as structured JSON
- Every Kafka consumer must be idempotent
- Use UUIDs for all primary keys
- Database migrations via golang-migrate (Go) or node-pg-migrate (Node.js)

## K8s
- Namespace: rideflow
- All secrets via K8s Secrets (never hardcoded)
- All config via ConfigMap: rideflow-config
- Resource limits defined for all containers

## Current Phase
[UPDATE THIS LINE each phase]
Phase 1 — Foundation: setting up Minikube + Kafka + Redis + PostgreSQL + RabbitMQ
