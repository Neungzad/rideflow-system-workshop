# RideFlow — Master Specification

> Real-Time Food Delivery & Transport Platform  
> Inspired by Grab / Lineman | Built for interview readiness & SDD learning

---

## 📖 How to Use This Spec (SDD Workflow)

This file is the **single source of truth** for the entire RideFlow system.  
You will use it in two ways:

1. **As a learning guide** — read each section before implementing, understand WHY before HOW
2. **As a Copilot CLI prompt** — feed sections to Copilot CLI to scaffold implementation

> See `LEARNING_WORKFLOW.md` for the phase-by-phase learning loop.

---

## 🗂️ Repository Structure

```
rideflow/
├── SPEC.md                          ← This file (master spec)
├── copilot-instructions.md                        ← Copilot CLI project context
├── LEARNING_WORKFLOW.md             ← SDD learning loop guide
├── specs/
│   ├── phase-1-foundation.md
│   ├── phase-2-user-service.md
│   ├── phase-3-order-service.md
│   ├── phase-4-matching-service.md
│   ├── phase-5-location-service.md
│   ├── phase-6-notification-rabbitmq.md
│   ├── phase-7-payment-merchant-rating.md
│   ├── phase-8-observability.md
│   ├── phase-9-aws-migration.md
│   └── phase-10-hardening-interview.md
├── services/
│   ├── api-gateway/                 ← Node.js
│   ├── user-service/                ← Go
│   ├── order-service/               ← Go
│   ├── merchant-service/            ← Node.js
│   ├── matching-service/            ← Go
│   ├── location-service/            ← Go
│   ├── notification-service/        ← Node.js
│   ├── payment-service/             ← Go
│   └── rating-service/              ← Node.js
├── workers/
│   ├── email-worker/                ← Node.js
│   ├── sms-worker/                  ← Node.js
│   └── rating-reminder-worker/      ← Node.js
├── k8s/
│   ├── namespace.yaml
│   ├── kafka/                       ← Strimzi CRDs
│   ├── rabbitmq/
│   ├── redis/
│   ├── postgres/
│   ├── elasticsearch/
│   ├── monitoring/                  ← Prometheus + Grafana
│   └── services/                   ← One folder per microservice
├── aws/
│   ├── eks/
│   ├── msk/
│   ├── sns-sqs/
│   └── terraform/
├── scripts/
│   ├── setup-minikube.sh
│   ├── seed-data.sh
│   └── load-test.js                 ← k6 load test
└── docs/
    ├── architecture-diagram.md
    ├── kafka-topic-map.md
    └── interview-prep.md
```

---

## 🎯 Project Scenario

**RideFlow** is a real-time food delivery and transport platform operating in Thailand.  
It handles order placement, driver matching, live GPS tracking, payments, and notifications at scale.

### Business Requirements

| Requirement               | Target                     | Why It Matters         |
| ------------------------- | -------------------------- | ---------------------- |
| Order throughput          | 5,000 orders/min peak      | Thai lunch/dinner rush |
| Driver match latency      | < 2 seconds                | User experience        |
| Location update frequency | Every 3 seconds per driver | Accurate ETA           |
| Notification delivery     | < 5 seconds after event    | Trust & transparency   |
| Payment processing        | Exactly-once, ordered      | No double charge       |
| System availability       | 99.9% uptime               | Revenue protection     |
| Audit log retention       | 90 days                    | Thai PDPA compliance   |

### Non-Functional Requirements

- **Zero message loss** — every order event must be durable
- **Idempotent consumers** — reprocessing a Kafka message must not create duplicate records
- **Graceful degradation** — if Matching Service is down, orders queue in Kafka until it recovers
- **Database per service** — no service reads another service's DB directly
- **All inter-service communication via Kafka** — no synchronous HTTP between internal services (except API Gateway → services for initial request)

---

## 🧩 Microservice Overview

| Service              | Language | Primary Role                    | DB                                  | Communicates Via                        |
| -------------------- | -------- | ------------------------------- | ----------------------------------- | --------------------------------------- |
| api-gateway          | Node.js  | Auth, rate limit, routing       | —                                   | HTTP (inbound), HTTP (to services)      |
| user-service         | Go       | Customer & driver profiles      | PostgreSQL                          | HTTP (from gateway), Kafka (publish)    |
| order-service        | Go       | Order lifecycle state machine   | PostgreSQL                          | Kafka (pub/sub)                         |
| merchant-service     | Node.js  | Restaurant & menu management    | PostgreSQL + **Redis (menu cache)** | HTTP (from gateway)                     |
| matching-service     | Go       | Assign nearest driver to order  | Redis                               | Kafka (pub/sub)                         |
| location-service     | Go       | Real-time GPS ingestion & cache | Redis                               | Kafka (consume driver.location)         |
| notification-service | Node.js  | Fan-out events to RabbitMQ/SNS  | —                                   | Kafka (consume), RabbitMQ/SNS (publish) |
| payment-service      | Go       | Charge, refund, wallet          | PostgreSQL                          | Kafka (pub/sub), RabbitMQ FIFO          |
| rating-service       | Node.js  | Post-delivery reviews           | PostgreSQL                          | Kafka (consume), HTTP (from gateway)    |

---

## 🗃️ Data Models

### User Service — PostgreSQL

```sql
-- users table (customers)
CREATE TABLE users (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(255) NOT NULL,
    email       VARCHAR(255) UNIQUE NOT NULL,
    phone       VARCHAR(20) UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role        VARCHAR(20) NOT NULL CHECK (role IN ('customer', 'driver', 'admin')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- drivers table (extended driver profile)
CREATE TABLE drivers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id),
    vehicle_type    VARCHAR(50) NOT NULL CHECK (vehicle_type IN ('motorcycle', 'car')),
    plate_number    VARCHAR(20) NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'offline'
                    CHECK (status IN ('offline', 'available', 'busy')),
    current_lat     DECIMAL(10, 8),
    current_lng     DECIMAL(11, 8),
    rating_avg      DECIMAL(3,2) DEFAULT 0.00,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_drivers_status ON drivers(status);
CREATE INDEX idx_drivers_user_id ON drivers(user_id);
```

### Order Service — PostgreSQL

```sql
-- orders table
CREATE TABLE orders (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID NOT NULL,
    driver_id       UUID,
    merchant_id     UUID NOT NULL,
    status          VARCHAR(30) NOT NULL DEFAULT 'pending'
                    CHECK (status IN (
                        'pending', 'confirmed', 'assigned',
                        'accepted', 'picked_up', 'delivered', 'cancelled'
                    )),
    total_amount    DECIMAL(10,2) NOT NULL,
    delivery_address TEXT NOT NULL,
    delivery_lat    DECIMAL(10,8) NOT NULL,
    delivery_lng    DECIMAL(11,8) NOT NULL,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- order_items table
CREATE TABLE order_items (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id    UUID NOT NULL REFERENCES orders(id),
    item_id     UUID NOT NULL,
    item_name   VARCHAR(255) NOT NULL,
    quantity    INT NOT NULL CHECK (quantity > 0),
    unit_price  DECIMAL(10,2) NOT NULL,
    subtotal    DECIMAL(10,2) NOT NULL
);

-- order_events table (audit trail for state transitions)
CREATE TABLE order_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id    UUID NOT NULL REFERENCES orders(id),
    event_type  VARCHAR(50) NOT NULL,
    payload     JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_orders_customer_id ON orders(customer_id);
CREATE INDEX idx_orders_driver_id ON orders(driver_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_order_events_order_id ON order_events(order_id);
```

### Merchant Service — PostgreSQL

```sql
-- restaurants table
CREATE TABLE restaurants (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(255) NOT NULL,
    address     TEXT NOT NULL,
    lat         DECIMAL(10,8) NOT NULL,
    lng         DECIMAL(11,8) NOT NULL,
    category    VARCHAR(100),
    is_open     BOOLEAN NOT NULL DEFAULT false,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- menu_items table
CREATE TABLE menu_items (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    name            VARCHAR(255) NOT NULL,
    description     TEXT,
    price           DECIMAL(10,2) NOT NULL,
    is_available    BOOLEAN NOT NULL DEFAULT true,
    category        VARCHAR(100)
);

CREATE INDEX idx_menu_items_restaurant ON menu_items(restaurant_id);
```

### Payment Service — PostgreSQL

```sql
-- wallets table
CREATE TABLE wallets (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID UNIQUE NOT NULL,
    balance     DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- transactions table
CREATE TABLE transactions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        UUID NOT NULL,
    payer_id        UUID NOT NULL,
    payee_id        UUID NOT NULL,
    amount          DECIMAL(10,2) NOT NULL,
    type            VARCHAR(30) NOT NULL CHECK (type IN ('charge', 'refund', 'top_up')),
    status          VARCHAR(20) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'completed', 'failed')),
    idempotency_key VARCHAR(255) UNIQUE NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_transactions_order_id ON transactions(order_id);
CREATE INDEX idx_transactions_idempotency ON transactions(idempotency_key);
```

### Rating Service — PostgreSQL

```sql
-- ratings table
CREATE TABLE ratings (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id    UUID UNIQUE NOT NULL,
    customer_id UUID NOT NULL,
    driver_id   UUID NOT NULL,
    score       INT NOT NULL CHECK (score BETWEEN 1 AND 5),
    comment     TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_ratings_driver_id ON ratings(driver_id);
```

### Redis — Matching & Location Services

```
# Driver availability (Matching Service)
KEY: driver:available:{driver_id}
TYPE: Hash
FIELDS: driver_id, vehicle_type, lat, lng, updated_at
TTL: 30 seconds (auto-expire if driver goes offline)

# Driver geospatial index (Matching Service)
KEY: drivers:geo
TYPE: GEO (sorted set)
USE: GEOADD / GEORADIUS commands for nearest driver lookup

# Live driver location (Location Service)
KEY: driver:location:{driver_id}
TYPE: Hash
FIELDS: lat, lng, heading, speed, updated_at
TTL: 10 seconds

# Rate limiting (API Gateway)
KEY: ratelimit:{user_id}:{minute}
TYPE: String (counter)
TTL: 60 seconds
```

### Redis — Merchant Service (Menu Cache) ⭐ Redis Practice Focus

> **Pattern:** Cache-Aside (Lazy Loading)  
> **API:** `GET /merchants/:id/menu`  
> **Why this API?** Menu data is read by every customer who opens a restaurant page but only written when a merchant updates their menu. Perfect read-heavy, write-rare cache candidate.

```
# Menu cache (Merchant Service)
KEY:   menu:{merchant_id}
TYPE:  String (serialized JSON)
TTL:   30 minutes (1800 seconds)
VALUE: full menu response JSON (array of menu_items)

# Cache invalidation key (for tracking)
KEY:   menu:updated:{merchant_id}
TYPE:  String (timestamp)
TTL:   no TTL (permanent until next update)
```

#### Cache-Aside Flow — GET /merchants/:id/menu

```
Client → GET /merchants/:id/menu
              │
              ▼
    ┌─────────────────────┐
    │  Redis GET          │
    │  menu:{merchant_id} │
    └────────┬────────────┘
             │
    ┌────────▼────────────┐      ┌──────────────────────────┐
    │   Cache HIT?        │─YES─►│  Return cached JSON      │
    └────────┬────────────┘      │  Add header:             │
             │ NO                │  X-Cache: HIT            │
             ▼                   └──────────────────────────┘
    ┌─────────────────────┐
    │  Query PostgreSQL   │
    │  SELECT * FROM      │
    │  menu_items WHERE   │
    │  restaurant_id = ?  │
    └────────┬────────────┘
             │
             ▼
    ┌─────────────────────┐
    │  Redis SET          │
    │  menu:{merchant_id} │
    │  EX 1800            │  ← 30 min TTL
    └────────┬────────────┘
             │
             ▼
    ┌─────────────────────┐
    │  Return response    │
    │  Add header:        │
    │  X-Cache: MISS      │
    └─────────────────────┘
```

#### Cache Invalidation — PUT /merchants/:id/menu (update item)

```
Merchant updates menu item
              │
              ▼
    ┌─────────────────────┐
    │  UPDATE menu_items  │
    │  in PostgreSQL      │
    └────────┬────────────┘
             │
             ▼
    ┌─────────────────────┐
    │  Redis DEL          │
    │  menu:{merchant_id} │  ← invalidate immediately
    └────────┬────────────┘
             │
             ▼
    ┌─────────────────────┐
    │  Next GET request   │
    │  will be cache MISS │
    │  → rebuilds cache   │
    └─────────────────────┘
```

#### Merchant Service — Redis Endpoints Summary

| Endpoint                                    | Redis Operation     | Key                  | TTL    |
| ------------------------------------------- | ------------------- | -------------------- | ------ |
| `GET /merchants/:id/menu`                   | GET → SET (on miss) | `menu:{merchant_id}` | 30 min |
| `PUT /merchants/:id/menu-items/:item_id`    | DEL (invalidate)    | `menu:{merchant_id}` | —      |
| `POST /merchants/:id/menu-items`            | DEL (invalidate)    | `menu:{merchant_id}` | —      |
| `DELETE /merchants/:id/menu-items/:item_id` | DEL (invalidate)    | `menu:{merchant_id}` | —      |

#### Merchant Service — New Endpoints (add to API spec)

```
GET /merchants/:id/menu
Response 200: { merchant_id, items: [...] }
Headers: X-Cache: HIT | MISS
Redis: GET menu:{merchant_id} → if miss, query DB then SET with 30min TTL

PUT /merchants/:id/menu-items/:item_id
Body: { name?, price?, description?, is_available? }
Response 200: { item_id, updated_at }
Redis: DEL menu:{merchant_id}  ← invalidate after DB update

POST /merchants/:id/menu-items
Body: { name, price, description?, category? }
Response 201: { item_id }
Redis: DEL menu:{merchant_id}  ← invalidate after DB insert

DELETE /merchants/:id/menu-items/:item_id
Response 204
Redis: DEL menu:{merchant_id}  ← invalidate after DB delete
```

#### Redis Commands You Will Practice

```javascript
// Cache-Aside: read
const cached = await redis.get(`menu:${merchantId}`);
if (cached) return JSON.parse(cached); // HIT

// Cache-Aside: populate after DB read
await redis.set(
  `menu:${merchantId}`,
  JSON.stringify(menuItems),
  "EX",
  1800, // TTL in seconds
);

// Invalidate on write
await redis.del(`menu:${merchantId}`);

// Inspect TTL (useful for debugging)
const ttl = await redis.ttl(`menu:${merchantId}`);
// Returns: remaining seconds, -1 (no TTL), -2 (key not found)
```

#### What to Observe While Testing

```bash
# Watch cache in action
redis-cli MONITOR

# Check if key exists and its TTL
redis-cli TTL menu:{some-merchant-id}

# Inspect cached value
redis-cli GET menu:{some-merchant-id} | jq .

# Check memory used by menu keys
redis-cli --scan --pattern 'menu:*' | xargs redis-cli MEMORY USAGE
```

#### Prometheus Metrics to Add for Cache

```
# Add these to merchant-service
menu_cache_hits_total       ← increment on HIT
menu_cache_misses_total     ← increment on MISS
menu_cache_invalidations_total ← increment on DEL

# Derived metric to watch in Grafana
Cache Hit Rate = hits / (hits + misses)
Target: > 80% during lunch/dinner peak
```

#### Interview Talking Points

> _"Why Cache-Aside and not Write-Through for menu data?"_  
> Write-Through updates the cache on every DB write — good when you always want the cache populated. Cache-Aside only populates on demand — better for menu data because some merchants may have zero traffic, so we avoid warming a cache nobody reads.

> _"What happens if Redis goes down?"_  
> The merchant-service falls back to PostgreSQL directly. We wrap the Redis call in try-catch — on any Redis error, we skip cache and serve from DB. The system degrades gracefully, just slower.

> _"How do you prevent cache stampede?"_  
> During high traffic, if the cache expires and 1000 requests hit simultaneously, all go to DB at once. Solution: use a short-TTL lock key (`menu:lock:{merchant_id}`) — first request acquires the lock, rebuilds cache, others wait or serve stale. We can implement this in Phase 7 as an advanced task.

---

## 📨 Kafka Topic Specification

> **On-Premise:** Apache Kafka via Strimzi Operator on Minikube  
> **AWS:** Amazon MSK (same topic names, same message schemas)

### Topic Configuration

| Topic               | Partitions | Replication Factor | Retention | Description                         |
| ------------------- | ---------- | ------------------ | --------- | ----------------------------------- |
| `order.created`     | 6          | 1 (dev) / 3 (prod) | 7 days    | New order placed by customer        |
| `order.assigned`    | 6          | 1 / 3              | 7 days    | Driver assigned by matching service |
| `order.accepted`    | 6          | 1 / 3              | 7 days    | Driver confirmed pickup             |
| `order.picked_up`   | 6          | 1 / 3              | 7 days    | Driver picked up food               |
| `order.delivered`   | 6          | 1 / 3              | 7 days    | Delivery completed                  |
| `order.cancelled`   | 6          | 1 / 3              | 7 days    | Order cancelled (any party)         |
| `driver.location`   | 12         | 1 / 3              | 1 hour    | High-freq GPS updates               |
| `payment.requested` | 6          | 1 / 3              | 7 days    | Payment trigger after delivery      |
| `payment.completed` | 6          | 1 / 3              | 7 days    | Payment success confirmation        |
| `notification.send` | 6          | 1 / 3              | 1 day     | Generic notification trigger        |

### Message Schemas (JSON)

```jsonc
// order.created
{
  "event_id": "uuid",
  "order_id": "uuid",
  "customer_id": "uuid",
  "merchant_id": "uuid",
  "merchant_lat": 13.7563,
  "merchant_lng": 100.5018,
  "delivery_lat": 13.7600,
  "delivery_lng": 100.5100,
  "total_amount": 350.00,
  "items": [
    { "item_id": "uuid", "name": "Pad Thai", "quantity": 2, "price": 175.00 }
  ],
  "created_at": "2025-01-01T12:00:00Z"
}

// order.assigned
{
  "event_id": "uuid",
  "order_id": "uuid",
  "driver_id": "uuid",
  "driver_name": "Somchai",
  "driver_lat": 13.7550,
  "driver_lng": 100.5000,
  "estimated_pickup_minutes": 5,
  "assigned_at": "2025-01-01T12:00:10Z"
}

// driver.location (high frequency — partition by driver_id)
{
  "driver_id": "uuid",
  "lat": 13.7552,
  "lng": 100.5005,
  "heading": 90,
  "speed_kmh": 30,
  "timestamp": "2025-01-01T12:00:03Z"
}

// payment.requested
{
  "event_id": "uuid",
  "order_id": "uuid",
  "customer_id": "uuid",
  "driver_id": "uuid",
  "amount": 350.00,
  "idempotency_key": "order_{order_id}_payment",
  "requested_at": "2025-01-01T12:30:00Z"
}

// notification.send
{
  "event_id": "uuid",
  "recipient_id": "uuid",
  "recipient_type": "customer | driver",
  "channel": "push | sms | email",
  "template": "order_assigned | order_picked_up | order_delivered",
  "data": { "order_id": "uuid", "driver_name": "Somchai" },
  "sent_at": "2025-01-01T12:00:11Z"
}
```

### Consumer Groups

```
order.created     → matching-service-cg
                  → notification-service-cg
                  → audit-service-cg

order.assigned    → order-service-cg
                  → notification-service-cg
                  → location-service-cg

order.delivered   → payment-service-cg
                  → notification-service-cg
                  → rating-service-cg
                  → analytics-cg

driver.location   → location-service-cg
                  → matching-service-cg

payment.completed → order-service-cg
                  → notification-service-cg
```

---

## 🐇 RabbitMQ Specification (On-Premise)

> **On-Premise:** RabbitMQ via Helm on Minikube  
> **AWS Equivalent:** Amazon SNS (fan-out) + Amazon SQS (queues)

### Exchange Design

```
EXCHANGE: notification.fanout
  Type: Fanout
  Durable: true
  Bindings:
    → queue: email.queue
    → queue: sms.queue
    → queue: rating.reminder.queue

EXCHANGE: payment.direct
  Type: Direct
  Durable: true
  Bindings:
    → queue: payment.queue (routing key: payment)

EXCHANGE: dlx.exchange (Dead Letter Exchange)
  Type: Direct
  Durable: true
  Bindings:
    → queue: dlq.email
    → queue: dlq.sms
    → queue: dlq.payment
```

### Queue Configuration

| Queue                   | Type               | Max Retries | DLQ           | TTL          |
| ----------------------- | ------------------ | ----------- | ------------- | ------------ |
| `email.queue`           | Standard           | 3           | `dlq.email`   | —            |
| `sms.queue`             | Standard           | 3           | `dlq.sms`     | —            |
| `rating.reminder.queue` | Standard + TTL     | 3           | —             | 30 min delay |
| `payment.queue`         | Quorum (FIFO-like) | 5           | `dlq.payment` | —            |

### Message Flow

```
Notification Service (Kafka consumer)
    │
    │ receives order.delivered from Kafka
    │
    ▼
Publish to notification.fanout exchange
    │
    ├──► email.queue       → Email Worker    → AWS SES / SendGrid
    ├──► sms.queue         → SMS Worker      → AWS SNS SMS / Twilio
    └──► rating.reminder   → Rating Worker   → waits 30min → HTTP to rating-service

Payment Service (Kafka consumer)
    │
    │ receives order.delivered from Kafka
    │
    ▼
Publish to payment.direct exchange
    │
    └──► payment.queue → Payment Worker → deduct wallet → publish payment.completed to Kafka
```

---

## ☁️ AWS SNS / SQS Specification (AWS Track)

### SNS Topics

| Topic Name               | Publisher            | Purpose                                   |
| ------------------------ | -------------------- | ----------------------------------------- |
| `rideflow-order-events`  | Notification Service | Fan-out order state changes to SQS queues |
| `rideflow-system-alerts` | CloudWatch Alarms    | Ops alerts via email/PagerDuty            |
| `rideflow-driver-surge`  | Matching Service     | Surge pricing alerts to regions           |

### SQS Queues

| Queue Name                       | Type     | Subscribed SNS          | Visibility Timeout | DLQ                         | Max Receive |
| -------------------------------- | -------- | ----------------------- | ------------------ | --------------------------- | ----------- |
| `rideflow-email-queue`           | Standard | `rideflow-order-events` | 30s                | `rideflow-dlq-email`        | 3           |
| `rideflow-sms-queue`             | Standard | `rideflow-order-events` | 30s                | `rideflow-dlq-sms`          | 3           |
| `rideflow-rating-reminder-queue` | Standard | `rideflow-order-events` | 30min delay        | —                           | 3           |
| `rideflow-payment-queue`         | **FIFO** | Direct publish          | 60s                | `rideflow-dlq-payment.fifo` | 5           |
| `rideflow-dlq-email`             | Standard | —                       | 300s               | —                           | —           |
| `rideflow-dlq-sms`               | Standard | —                       | 300s               | —                           | —           |
| `rideflow-dlq-payment`           | FIFO     | —                       | 300s               | —                           | —           |

### SNS → SQS Fan-out Flow (replaces RabbitMQ on AWS)

```
Notification Service
    │ publish
    ▼
SNS: rideflow-order-events
    │
    ├──► SQS: email-queue       → Lambda: email-handler
    ├──► SQS: sms-queue         → Lambda: sms-handler
    └──► SQS: rating-reminder   → Lambda: rating-reminder-handler (30min delay)

Payment Service
    │ publish directly (bypasses SNS — needs FIFO guarantee)
    ▼
SQS FIFO: payment-queue
    │
    └──► Lambda / ECS: payment-worker
```

---

## 🔌 API Specifications

### API Gateway — Routing Table

All external traffic enters via API Gateway at port `8080`.  
JWT validation happens here before forwarding.

| Method | Path                  | Forward To            | Auth Required  |
| ------ | --------------------- | --------------------- | -------------- |
| POST   | `/auth/register`      | user-service:8001     | No             |
| POST   | `/auth/login`         | user-service:8001     | No             |
| GET    | `/users/me`           | user-service:8001     | Yes            |
| PUT    | `/drivers/status`     | user-service:8001     | Yes (driver)   |
| GET    | `/merchants`          | merchant-service:8002 | No             |
| GET    | `/merchants/:id/menu` | merchant-service:8002 | No             |
| POST   | `/orders`             | order-service:8003    | Yes (customer) |
| GET    | `/orders/:id`         | order-service:8003    | Yes            |
| PUT    | `/orders/:id/status`  | order-service:8003    | Yes (driver)   |
| POST   | `/locations`          | location-service:8004 | Yes (driver)   |
| GET    | `/ratings/:order_id`  | rating-service:8005   | Yes            |
| POST   | `/ratings`            | rating-service:8005   | Yes (customer) |

### User Service — Endpoints

```
POST /auth/register
Body: { name, email, phone, password, role }
Response 201: { user_id, token }

POST /auth/login
Body: { email, password }
Response 200: { token, user_id, role }

GET /users/me
Header: Authorization: Bearer <token>
Response 200: { id, name, email, phone, role, driver_profile? }

PUT /drivers/status
Header: Authorization: Bearer <token>
Body: { status: "available" | "busy" | "offline" }
Response 200: { driver_id, status }
```

### Order Service — Endpoints

```
POST /orders
Body: { merchant_id, delivery_address, delivery_lat, delivery_lng, items[], notes? }
Response 201: { order_id, status: "pending", estimated_total }
Side Effect: publish order.created to Kafka

GET /orders/:id
Response 200: { order + latest status + driver info if assigned }

PUT /orders/:id/status
Body: { status: "accepted" | "picked_up" | "delivered" | "cancelled" }
Response 200: { order_id, status, updated_at }
Side Effect: publish matching Kafka topic
```

### Location Service — Endpoints

```
POST /locations
Header: Authorization: Bearer <token> (driver only)
Body: { lat, lng, heading, speed_kmh }
Response 202: { received: true }
Side Effect: publish driver.location to Kafka
```

### Rating Service — Endpoints

```
POST /ratings
Body: { order_id, score (1-5), comment? }
Response 201: { rating_id }

GET /ratings/:order_id
Response 200: { order_id, score, comment, created_at }
```

---

## ☸️ Kubernetes Specification

### Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: rideflow
```

### Standard Deployment Template (per service)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {service-name}
  namespace: rideflow
spec:
  replicas: 2
  selector:
    matchLabels:
      app: {service-name}
  template:
    metadata:
      labels:
        app: {service-name}
    spec:
      containers:
        - name: {service-name}
          image: rideflow/{service-name}:latest
          ports:
            - containerPort: {port}
          env:
            - name: DB_HOST
              valueFrom:
                secretKeyRef:
                  name: {service-name}-secrets
                  key: db_host
            - name: KAFKA_BROKERS
              valueFrom:
                configMapKeyRef:
                  name: rideflow-config
                  key: kafka_brokers
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
          readinessProbe:
            httpGet:
              path: /health
              port: {port}
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: {port}
            initialDelaySeconds: 30
            periodSeconds: 10
```

### HorizontalPodAutoscaler (Matching + Location Services)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: matching-service-hpa
  namespace: rideflow
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: matching-service
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### Strimzi Kafka CRD

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: rideflow-kafka
  namespace: rideflow
spec:
  kafka:
    replicas: 1 # 3 for production
    version: 3.7.0
    storage:
      type: ephemeral # persistent for production
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      default.replication.factor: 1
  zookeeper:
    replicas: 1
    storage:
      type: ephemeral
```

### KafkaTopic CRD (one per topic)

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: order-created
  namespace: rideflow
  labels:
    strimzi.io/cluster: rideflow-kafka
spec:
  partitions: 6
  replicas: 1
  config:
    retention.ms: 604800000 # 7 days
    cleanup.policy: delete
```

### Ingress (Nginx)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rideflow-ingress
  namespace: rideflow
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/rate-limit: "100"
spec:
  ingressClassName: nginx
  rules:
    - host: rideflow.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-gateway
                port:
                  number: 8080
```

### Shared ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rideflow-config
  namespace: rideflow
data:
  kafka_brokers: "rideflow-kafka-kafka-bootstrap.rideflow.svc.cluster.local:9092"
  rabbitmq_host: "rabbitmq.rideflow.svc.cluster.local"
  redis_host: "redis.rideflow.svc.cluster.local"
  environment: "development"
```

---

## 📊 Observability Specification

### Prometheus Metrics (each service must expose)

```
# HTTP metrics
http_requests_total{method, path, status}
http_request_duration_seconds{method, path}

# Kafka metrics (consumer)
kafka_consumer_lag{topic, partition, consumer_group}
kafka_messages_consumed_total{topic}

# Business metrics
orders_created_total
orders_delivered_total
driver_match_duration_seconds
payment_processed_total{status}
```

### Grafana Dashboards to Build

| Dashboard             | Key Panels                                             |
| --------------------- | ------------------------------------------------------ |
| **Order Flow**        | Orders/min, delivery success rate, cancellation rate   |
| **Driver Matching**   | Match latency p50/p95/p99, active drivers, queue depth |
| **Location Tracking** | GPS updates/sec, location service lag                  |
| **Kafka Health**      | Consumer lag per group, message rate per topic         |
| **Payment**           | Payment success rate, DLQ depth, processing time       |
| **Infrastructure**    | Pod CPU/Memory, node status, HPA scaling events        |

### Kibana Index Patterns

```
rideflow-orders-*      → order lifecycle logs
rideflow-matching-*    → driver assignment logs
rideflow-payment-*     → payment audit logs
rideflow-errors-*      → all error logs across services
```

---

## ☁️ AWS Architecture (Track 2)

### Service Mapping

| On-Premise             | AWS Service                             | Config Notes                  |
| ---------------------- | --------------------------------------- | ----------------------------- |
| Minikube               | **EKS**                                 | Node group: t3.medium x3      |
| Kafka (Strimzi)        | **Amazon MSK**                          | kafka.t3.small, 3 brokers     |
| Redis                  | **ElastiCache for Redis**               | cache.t3.micro cluster mode   |
| PostgreSQL             | **Aurora PostgreSQL**                   | db.t3.medium, Multi-AZ        |
| Elasticsearch + Kibana | **Amazon OpenSearch**                   | t3.small.search               |
| RabbitMQ               | **Amazon SQS + SNS**                    | See SNS/SQS spec above        |
| Nginx Ingress          | **AWS Load Balancer Controller + ALB**  | SSL termination               |
| Local Registry         | **Amazon ECR**                          | One repo per service          |
| Manual deploy          | **CodePipeline + CodeBuild**            | Build → push ECR → deploy EKS |
| Prometheus/Grafana     | **CloudWatch + Amazon Managed Grafana** | IRSA for metrics              |

### VPC Design

```
VPC: 10.0.0.0/16
├── Public Subnets (2 AZs)
│   ├── 10.0.1.0/24 (ap-southeast-1a)
│   └── 10.0.2.0/24 (ap-southeast-1b)
│   └── Resources: ALB, NAT Gateway
│
└── Private Subnets (2 AZs)
    ├── 10.0.11.0/24 (ap-southeast-1a)
    └── 10.0.12.0/24 (ap-southeast-1b)
    └── Resources: EKS nodes, MSK, Aurora, ElastiCache
```

### IAM Roles for Service Accounts (IRSA)

```
payment-service-sa   → SQS:SendMessage (payment-queue)
                     → SQS:ReceiveMessage (payment-queue)
                     → SecretsManager:GetSecretValue

notification-service-sa → SNS:Publish (rideflow-order-events)
                        → SQS:SendMessage

order-service-sa     → SecretsManager:GetSecretValue
                     → MSK:Connect

all-services-sa      → CloudWatch:PutMetricData
                     → ECR:GetAuthorizationToken
```

---

## 📅 Workshop Phases

### Phase 1 — Foundation (Week 1)

**Goal:** Understand and run the full infrastructure stack locally

**Learning objectives:**

- Understand what Minikube is and how K8s works locally
- Understand Kafka's role as event bus (producers, consumers, topics, partitions)
- Understand why each infrastructure component exists

**Tasks:**

1. Install Minikube, kubectl, Helm
2. Deploy Kafka via Strimzi Operator
3. Deploy Redis (Helm)
4. Deploy PostgreSQL (Helm, one instance per service)
5. Deploy RabbitMQ (Helm)
6. Verify all pods running, Kafka topics created
7. Test: produce + consume a test message manually

**Reference spec:** `specs/phase-1-foundation.md`

---

### Phase 2 — User Service (Week 2)

**Goal:** Build first Go microservice with JWT auth

**Learning objectives:**

- Go project structure for a microservice
- JWT authentication pattern
- Database per service — why and how
- Dockerize a Go app

**Tasks:**

1. Scaffold user-service in Go (chi or gin router)
2. Implement register, login, get profile endpoints
3. JWT middleware
4. PostgreSQL connection + migrations (golang-migrate)
5. Docker build + push to Minikube local registry
6. Write K8s Deployment + Service + Secret YAML
7. Test via curl through API Gateway route

**Reference spec:** `specs/phase-2-user-service.md`

---

### Phase 3 — Order Service + Kafka Producer (Week 3)

**Goal:** Implement order state machine and first Kafka publish

**Learning objectives:**

- State machine pattern for order lifecycle
- Kafka producer in Go (Sarama or confluent-kafka-go)
- Idempotency key pattern
- Event-driven design: why we publish instead of calling matching service directly

**Tasks:**

1. Scaffold order-service in Go
2. Implement order CRUD with state machine
3. On order creation → publish to `order.created` Kafka topic
4. On status change → publish matching topic
5. Deploy to K8s, verify Kafka message with kafka-console-consumer

**Reference spec:** `specs/phase-3-order-service.md`

---

### Phase 4 — Matching Service + Kafka Consumer (Week 4)

**Goal:** Consume Kafka events, implement Redis GeoHash driver matching

**Learning objectives:**

- Kafka consumer groups and offset management
- Redis GEO commands (GEOADD, GEORADIUS)
- Why matching uses Redis not PostgreSQL (speed)
- Your roadside dispatch experience maps here

**Tasks:**

1. Scaffold matching-service in Go
2. Consume `order.created` topic
3. Query Redis GEO for nearest available driver
4. Publish `order.assigned` to Kafka
5. Handle edge case: no available driver (retry logic)
6. Deploy + verify end-to-end: order → Kafka → match → assigned

**Reference spec:** `specs/phase-4-matching-service.md`

---

### Phase 5 — Location Service + High-Freq Kafka (Week 5)

**Goal:** Handle high-frequency GPS stream efficiently

**Learning objectives:**

- High-frequency Kafka topics (partitioning strategy by driver_id)
- Redis as real-time position cache
- Why 12 partitions for driver.location vs 6 for orders
- Backpressure handling

**Tasks:**

1. Scaffold location-service in Go
2. HTTP endpoint: driver posts GPS every 3s
3. Publish to `driver.location` Kafka (partitioned by driver_id)
4. Consumer: write to Redis with 10s TTL
5. Matching service reads from Redis instead of consuming location topic
6. Load test: simulate 100 concurrent drivers

**Reference spec:** `specs/phase-5-location-service.md`

---

### Phase 6 — Notification + RabbitMQ Fan-out (Week 6)

**Goal:** Implement async notification fan-out via RabbitMQ

**Learning objectives:**

- RabbitMQ exchanges (fanout vs direct vs topic)
- Dead Letter Queue pattern
- Async worker pattern in Node.js
- Why RabbitMQ for this instead of more Kafka topics

**Tasks:**

1. Scaffold notification-service in Node.js
2. Consume `order.delivered`, `order.assigned` etc. from Kafka
3. Publish to RabbitMQ fanout exchange
4. Build email-worker (Node.js) — consume email.queue
5. Build sms-worker (Node.js) — consume sms.queue
6. Build rating-reminder-worker — consume with 30min TTL delay
7. Configure DLQ for all queues
8. Deploy all workers to K8s

**Reference spec:** `specs/phase-6-notification-rabbitmq.md`

---

### Phase 7 — Payment + Merchant + Rating (Week 7)

**Goal:** Complete remaining services, implement FIFO payment queue, and practice Redis Cache-Aside pattern

**Learning objectives:**

- FIFO queue pattern (exactly-once, ordered processing)
- Idempotency key in payment — why critical
- **Redis Cache-Aside pattern** — the most common Redis pattern in production
- Cache invalidation strategy — when and how to invalidate
- Cache hit rate as a performance metric
- Graceful degradation — what happens when Redis is unavailable

**Tasks:**

1. Scaffold payment-service in Go
2. Consume `order.delivered`, publish to RabbitMQ payment.queue (FIFO/Quorum)
3. Payment worker: deduct wallet, idempotency check, publish `payment.completed`
4. Scaffold merchant-service in Node.js (menu CRUD with PostgreSQL)
5. **⭐ Add Redis Cache-Aside to `GET /merchants/:id/menu`**
   - On cache HIT: return from Redis, add `X-Cache: HIT` header
   - On cache MISS: query PostgreSQL, store in Redis (30min TTL), add `X-Cache: MISS`
   - On Redis error: fallback to PostgreSQL silently (graceful degradation)
6. **⭐ Add cache invalidation to all menu write endpoints**
   - `PUT /menu-items/:id`, `POST /menu-items`, `DELETE /menu-items/:id` → DEL cache key
7. **⭐ Add Prometheus metrics: `menu_cache_hits_total`, `menu_cache_misses_total`**
8. **⭐ Test and observe with `redis-cli MONITOR`** — watch cache in real-time
9. Scaffold rating-service in Node.js (post + get review)
10. Wire rating-reminder-worker → POST /ratings endpoint

**Redis Commands Practiced This Phase:**
`GET` · `SET EX` · `DEL` · `TTL` · `MONITOR` · `MEMORY USAGE`

**The Learning Moment:** After wiring the cache, hit `GET /merchants/:id/menu` twice in a row.
Watch the response time drop from ~20ms (DB) to ~1ms (Redis). That's the value of caching.

**Advanced Task (if time allows):**
Implement a simple cache stampede lock using `SET NX` (SET if Not eXists) to prevent
thundering herd when cache expires during peak traffic.

**Reference spec:** `specs/phase-7-payment-merchant-rating.md`

---

### Phase 8 — Observability (Week 8)

**Goal:** Full visibility into system health and business metrics

**Learning objectives:**

- Prometheus scraping pattern (pull model)
- Grafana dashboard design
- Kafka consumer lag as key health signal
- Structured logging for Kibana

**Tasks:**

1. Add Prometheus metrics to all services
2. Deploy Prometheus + Grafana via Helm
3. Build 4 core dashboards (Order Flow, Matching, Kafka Health, Infrastructure)
4. Deploy Elasticsearch + Kibana via Helm
5. Add structured JSON logging to all services → Kibana index
6. Set up alert: consumer lag > 1000 → notify

**Reference spec:** `specs/phase-8-observability.md`

---

### Phase 9 — AWS Migration (Week 9)

**Goal:** Deploy same system to AWS, replace on-prem tools with managed services

**Learning objectives:**

- EKS vs Minikube differences
- MSK configuration (why managed Kafka)
- SNS + SQS replacing RabbitMQ
- IRSA — why not use access keys in pods
- Aurora vs plain PostgreSQL

**Tasks:**

1. Push all images to ECR
2. Create EKS cluster (eksctl)
3. Deploy K8s manifests (same YAML, update image URLs)
4. Create MSK cluster, update Kafka config
5. Create Aurora PostgreSQL, run migrations
6. Replace RabbitMQ → SNS topic + SQS queues
7. Update notification-service to publish to SNS instead of RabbitMQ
8. Deploy Lambda workers for email/sms/rating
9. Configure IRSA for all service accounts
10. Test end-to-end on AWS

**Reference spec:** `specs/phase-9-aws-migration.md`

---

### Phase 10 — Hardening + Interview Prep (Week 10)

**Goal:** Production-grade polish and interview confidence

**Learning objectives:**

- CI/CD pipeline design
- Load testing methodology
- Failure mode analysis
- Architecture walkthrough skills

**Tasks:**

1. Set up CodePipeline → CodeBuild → ECR → EKS deploy
2. Add WAF to ALB
3. Configure Secrets Manager rotation
4. k6 load test: 1000 concurrent orders
5. Practice: draw architecture from memory in 5 minutes
6. Practice: answer 10 system design questions (see interview-prep.md)

**Reference spec:** `specs/phase-10-hardening-interview.md`

---

## 🎤 Interview Answer Templates

### "Design a real-time food delivery matching system"

> "I built this. We have an Order Service that publishes to a Kafka topic when an order is created. The Matching Service consumes that topic and queries Redis GEO commands to find the nearest available driver. Driver availability is maintained via a separate high-frequency location stream — also through Kafka — that updates Redis with a short TTL. Once matched, we publish to order.assigned, which multiple consumer groups pick up independently: Order Service updates DB state, Notification Service fans out to RabbitMQ queues for push/SMS, and Location Service starts tracking."

### "Kafka vs SQS — when do you use which?"

> "Kafka for high-throughput, replayable, ordered event streams between internal services — like our order lifecycle and location updates. SQS for isolated async task queues where one worker picks up one job — like payment processing where we need exactly-once semantics and a FIFO guarantee. On AWS we also add SNS in front of SQS for fan-out: one SNS publish fans out to email queue, SMS queue, and rating reminder queue without the publisher knowing how many downstream consumers exist."

### "How do you handle a service crashing without losing data?"

> "Kafka retains messages based on retention policy — 7 days for order events. When a service recovers, it continues from its last committed offset. For RabbitMQ queues, messages are durable and survive broker restart. For the payment queue specifically, we use a Quorum queue in RabbitMQ (FIFO-equivalent) with a DLQ, so failed payments never disappear — they land in the DLQ and trigger a CloudWatch alarm."

---

## 🧒 Kid Version — Explain the Whole System

Imagine RideFlow is a **really organized toy delivery service** at school:

- **Kafka** is the **school announcement board** — when something happens (new order, driver found, food picked up), someone writes it on the board. Different people read different sections of the board.
- **RabbitMQ / SQS** is a **to-do tray on each teacher's desk** — the board tells the teacher _"send this kid an SMS"_, the task goes in the tray, and the teacher does it one by one.
- **SNS** is the **school PA system** — one announcement automatically goes to every classroom at once.
- **Redis** is a **whiteboard near the door** showing where every delivery person is right now — very fast to read.
- **Kubernetes** is the **school principal** — if a teacher is sick (pod crashes), the principal immediately finds a replacement. If too many orders come in (lunch rush), the principal adds more teachers automatically.
- **PostgreSQL** is the **official grade book** — slow to look at but never loses anything.
- **Minikube** is practicing in the **school gym** before the real school opens.
- **AWS EKS** is the **real school** — bigger, professional, managed by experts.
