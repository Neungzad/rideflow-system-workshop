# RideFlow — SDD Learning Workflow

> How to use SPEC.md + Copilot CLI to learn AND build at the same time

---

## 🧠 The Core Philosophy

> **Don't just generate code. Understand it first, then generate, then own it.**

Most people use AI to skip learning. This workflow uses AI to **accelerate and deepen** learning.  
The difference: you always know WHY before Copilot CLI generates the HOW.

---

## 🔄 The Learning Loop (Per Phase)

Run this loop for every phase in SPEC.md:

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   1. READ     →  Read the phase spec section        │
│      ↓                                              │
│   2. DRAW     →  Draw the design yourself (paper)   │
│      ↓                                              │
│   3. QUESTION →  Ask Copilot to explain what's       │
│                  unclear before coding              │
│      ↓                                              │
│   4. ATTEMPT  →  Try to write the key part yourself │
│                  (even just the skeleton)           │
│      ↓                                              │
│   5. GENERATE →  Feed spec to Copilot CLI           │
│                  to scaffold full implementation    │
│      ↓                                              │
│   6. REVIEW   →  Read generated code line by line  │
│                  ask "why is this here?"            │
│      ↓                                              │
│   7. MODIFY   →  Change something. Add a feature.  │
│                  Break it. Fix it yourself.         │
│      ↓                                              │
│   8. EXPLAIN  →  Write 3 sentences explaining      │
│                  what you built (interview prep)    │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## 🖥️ Copilot CLI Setup

### 1. Install Copilot CLI

```bash
cd ~/rideflow
Copilot
```

### 2. Create copilot-instructions.md at Repo Root

This tells Copilot CLI the full context of your project.  
**Critical:** Without this, Copilot CLI treats every file in isolation.

```markdown
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
```

### 3. Update copilot-instructions.md Each Phase

Always update the `## Current Phase` line before starting a new phase.  
This keeps Copilot CLI focused on what you're building now.

---

## 💬 How to Talk to Copilot CLI (Phase by Phase)

### Phase 1 — Infrastructure Setup

**Step 1: Ask for explanation first**

```
Copilot> Read SPEC.md section "Kubernetes Specification" and "Kafka Topic Specification".
        Explain in simple terms: why do we use Strimzi Operator instead of
        installing Kafka directly? What is a CRD?
```

**Step 2: Generate setup script**

```
Copilot> Based on SPEC.md Phase 1 tasks, create a shell script
        scripts/setup-minikube.sh that:
        - Starts Minikube with enough resources (4 CPU, 8GB RAM)
        - Installs Strimzi Operator via kubectl
        - Applies the Kafka CRD from SPEC.md
        - Creates all KafkaTopic CRDs from the Kafka Topic Specification table
        - Installs Redis via Helm chart
        - Installs RabbitMQ via Helm chart
        - Installs PostgreSQL via Helm (5 instances, one per service)
        Add a wait/health check after each step.
```

**Step 3: Generate K8s manifests**

```
Copilot> Create k8s/kafka/kafka-cluster.yaml using the Strimzi Kafka CRD
        from SPEC.md. Then create one KafkaTopic YAML for each topic
        in the Kafka Topic Specification table. Put them in k8s/kafka/topics/
```

**Step 4: Review and modify**

- Open the generated YAMLs
- Understand each field
- Try changing `partitions: 6` to `partitions: 3` on a low-priority topic
- Ask: _"What happens if I set retention.ms too low on driver.location?"_

---

### Phase 2 — User Service

**Step 1: Understand before generating**

```
Copilot> Explain the JWT authentication flow in SPEC.md User Service section.
        Walk me through: what happens from the moment a user POSTs /auth/login
        to when they make a request to GET /users/me?
        Focus on where the token is created, validated, and what data it carries.
```

**Step 2: Scaffold the service**

```
Copilot> Create the user-service in Go at services/user-service/.
        Follow SPEC.md: User Service Endpoints and User Service PostgreSQL schema.
        Use: chi router, pgx/v5 for postgres, golang-jwt/jwt for JWT.
        Structure: cmd/main.go, internal/handler/, internal/repository/,
        internal/middleware/, internal/model/
        Include: GET /health, structured JSON logging, graceful shutdown.
        Do NOT implement everything — scaffold the structure with TODO comments
        for business logic. I will implement the logic myself.
```

**Step 3: Implement logic yourself**

- Fill in the `TODO` comments yourself
- This is where real learning happens
- If stuck, ask: _"How do I hash a password in Go? Show me just the function, not the full file."_

**Step 4: Generate K8s manifests**

```
Copilot> Create K8s manifests for user-service in k8s/services/user-service/.
        Include: Deployment, Service (ClusterIP), Secret template, ConfigMap reference.
        Use the standard Deployment template from SPEC.md.
        Service port: 8001
```

---

### Phase 3 — Order Service + First Kafka Publish

**Step 1: Understand the state machine**

```
Copilot> Draw a state diagram for the order lifecycle from SPEC.md
        (pending → confirmed → assigned → accepted → picked_up → delivered | cancelled).
        For each transition, tell me: what triggers it, what Kafka topic it publishes to,
        and what other services will react.
```

**Step 2: Scaffold with Kafka producer**

```
Copilot> Scaffold order-service in Go at services/order-service/.
        Same structure as user-service.
        Key requirement: after creating an order, publish to Kafka topic "order.created"
        using the message schema from SPEC.md Kafka Topic Specification.
        Use Sarama library for Kafka.
        Show me the Kafka producer setup and ONE publish function.
        Leave the rest as TODO for me to fill in.
```

**The key learning moment:** Understand the producer config:

```
Copilot> Explain these Kafka producer settings and why each matters
        for our payment use case:
        - acks (0, 1, all)
        - retries
        - idempotent producer
        - compression
```

---

### Phase 4 — Matching Service (Your Strongest Phase)

**This is where your roadside dispatch experience matters most.**

**Step 1: Connect your experience**

```
Copilot> In my previous job with a roadside assistance system, we had:
        - A dispatcher who manually calls the nearest available technician
        - Technicians report their location every 5 minutes
        - Jobs are assigned based on distance and availability

        Map this experience to the RideFlow Matching Service design in SPEC.md.
        What are the technical equivalents? What would we do differently at scale?
```

**Step 2: Understand Redis GEO**

```
Copilot> Explain Redis GEO commands with a real example using driver coordinates
        in Bangkok. Show me GEOADD and GEORADIUS with actual lat/lng values.
        Why is this faster than doing distance calculation in PostgreSQL?
```

**Step 3: Scaffold**

```
Copilot> Scaffold matching-service in Go.
        Core logic: consume order.created from Kafka,
        call Redis GEORADIUS to find nearest available driver within 5km,
        publish order.assigned to Kafka.
        Show the Kafka consumer setup with consumer group "matching-service-cg"
        and the Redis GEO query. Leave the full error handling as TODO.
```

---

### Phase 6 — Notification + RabbitMQ Fan-out (Key Concept Phase)

**Step 1: Understand exchanges before coding**

```
Copilot> Explain RabbitMQ exchange types with a visual example:
        - Fanout exchange (our notification use case)
        - Direct exchange (our payment use case)
        - Topic exchange (when would we use this instead?)
        Use the RideFlow notification flow from SPEC.md as context.
```

**Step 2: Understand why RabbitMQ here and not more Kafka**

```
Copilot> In SPEC.md, we use Kafka for order events between services,
        but RabbitMQ for the notification fan-out to workers.
        Why not just use more Kafka topics for email/sms/rating queues?
        What does RabbitMQ give us that Kafka doesn't, and vice versa?
        Help me form a clear interview answer for this question.
```

**Step 3: Generate**

```
Copilot> Create notification-service in Node.js at services/notification-service/.
        It should: consume order.delivered from Kafka using kafkajs,
        then publish to RabbitMQ notification.fanout exchange using amqplib.
        Also create email-worker in workers/email-worker/ that consumes
        email.queue from RabbitMQ and logs the email content (no real sending yet).
        Include dead letter queue configuration from SPEC.md RabbitMQ Specification.
```

---

### Phase 7 — Payment + Merchant + Rating (Key Redis Phase)

**Step 1: Understand Cache-Aside before touching code**

```
Copilot> Explain the Cache-Aside (Lazy Loading) pattern using the
        GET /merchants/:id/menu example from SPEC.md.
        Draw the full flow: what happens on a cache HIT vs a cache MISS?
        Why do we use Cache-Aside here instead of Write-Through?
```

**Step 2: Understand cache invalidation (the hard part)**

```
Copilot> In SPEC.md Redis Merchant Service section, we DEL the cache key
        on every menu write operation.
        What are the risks of this approach?
        What is the difference between:
        1. Delete on write (what we do)
        2. Update on write (write-through)
        3. Let TTL expire naturally
        When would you choose each strategy?
```

**Step 3: Scaffold merchant-service WITH Redis — but leave cache logic empty**

```
Copilot> Scaffold merchant-service in Node.js at services/merchant-service/.
        Use Express + ioredis + pg.
        Implement the restaurant and menu_items DB schema from SPEC.md.
        For GET /merchants/:id/menu:
        - Add the Redis client connection setup
        - Add a cacheGet() and cacheSet() helper function
        - Add TODO comments where Cache-Aside logic should go
        - Return the DB response directly for now
        DO NOT implement the cache logic yet — I will do that myself.
```

**Step 4: Implement Cache-Aside yourself (most important step)**

Using only the Redis commands from SPEC.md, fill in the TODOs:

```javascript
// Fill this in yourself — don't ask Copilot CLI yet
async function getMenu(req, res) {
  const { id } = req.params;
  const cacheKey = `menu:${id}`;

  // TODO: try Redis GET
  // TODO: if HIT, return with X-Cache: HIT header
  // TODO: if MISS or error, continue to DB
  // TODO: query PostgreSQL for menu items
  // TODO: SET in Redis with 30min TTL
  // TODO: return with X-Cache: MISS header
}
```

**Step 5: Verify with redis-cli**

```bash
# In one terminal — watch all Redis commands in real-time
redis-cli MONITOR

# In another terminal — hit the endpoint twice
curl http://rideflow.local/merchants/{id}/menu   # MISS
curl http://rideflow.local/merchants/{id}/menu   # HIT

# Check TTL
redis-cli TTL menu:{id}

# See the cached value
redis-cli GET menu:{id} | jq .
```

**Step 6: Test cache invalidation**

```bash
# Update a menu item
curl -X PUT http://rideflow.local/merchants/{id}/menu-items/{item_id} \
  -d '{"price": 200}'

# Check cache is gone
redis-cli EXISTS menu:{id}    # should return 0

# Next GET rebuilds cache
curl http://rideflow.local/merchants/{id}/menu   # MISS again — price updated
```

**Step 7: Add Prometheus metrics**

```
Copilot> Add three Prometheus counters to merchant-service:
        menu_cache_hits_total, menu_cache_misses_total, menu_cache_invalidations_total
        Increment the right counter in the cache logic I already wrote.
        Show me only the metric registration and increment lines — not the full file.
```

**Step 8: Implement graceful degradation**

```
Copilot> In my getMenu handler, the Redis call is inside a try-catch.
        Show me the correct pattern to:
        - On Redis connection error → log warning, skip to DB query
        - Never let a Redis failure return a 500 to the client
        - Add a counter: redis_errors_total
        Keep it minimal — just the error handling wrapper.
```

### Phase 9 — AWS Migration

**Step 1: Understand what changes and what doesn't**

```
Copilot> Compare the on-premise and AWS stacks from SPEC.md side by side.
        For each replacement (e.g. Kafka→MSK, RabbitMQ→SNS+SQS):
        - What code changes are needed?
        - What stays exactly the same?
        - What new AWS-specific concepts must I understand?
        Focus on SNS+SQS replacing RabbitMQ — this is the biggest conceptual shift.
```

**Step 2: Understand IRSA (critical AWS K8s concept)**

```
Copilot> Explain IRSA (IAM Roles for Service Accounts) from scratch.
        Why can't I just use an AWS access key inside a pod?
        Walk through the IRSA setup for payment-service-sa from SPEC.md.
        What does the trust policy look like?
```

**Step 3: Update notification service for SNS**

```
Copilot> Update services/notification-service/ to support two modes:
        - LOCAL mode: publish to RabbitMQ fanout exchange (existing code)
        - AWS mode: publish to SNS topic "rideflow-order-events" using AWS SDK v3
        Mode selected by ENV variable: NOTIFICATION_BACKEND=rabbitmq|sns
        This lets the same service work for both tracks without code duplication.
```

---

## 📝 After Each Phase — Write It Down

After completing each phase, write 3–5 sentences in `docs/learnings/phase-N.md`:

```markdown
# Phase 4 — Matching Service Learnings

## What I built

The Matching Service consumes the order.created Kafka topic and uses
Redis GEORADIUS to find the nearest available driver. It publishes
the result to order.assigned for downstream services.

## What surprised me

Redis GEORADIUS is much simpler than I expected — two lines to query
nearest driver vs writing a Haversine formula in SQL.

## How this maps to my roadside experience

The Redis GEO index is exactly like our dispatcher's map view,
except it's queried programmatically in < 1ms instead of visually.

## Interview answer for this phase

"The matching service is event-driven — it wakes up when Kafka delivers
an order, finds the nearest driver using Redis geospatial indexing,
and publishes the assignment back to Kafka for all downstream services."
```

This is your interview cheat sheet. After 10 phases, you have 10 ready-made answers.

---

## 🚫 What NOT to Do

| Temptation                                           | Why It Kills Learning                                  |
| ---------------------------------------------------- | ------------------------------------------------------ |
| Ask Copilot CLI to implement everything at once      | You won't understand any of it                         |
| Skip the DRAW step                                   | You lose the mental model                              |
| Never read generated code                            | You can't explain it in an interview                   |
| Use Copilot CLI to fix every error immediately       | Debugging IS learning                                  |
| Skip updating copilot-instructions.md between phases | Copilot CLI loses context, generates inconsistent code |

---

## ✅ Signs You've Actually Learned Each Phase

Before moving to the next phase, you should be able to:

- [ ] Draw the component and its connections from memory (no looking at SPEC.md)
- [ ] Explain it in 3 sentences to someone non-technical
- [ ] Answer: _"What happens if this component goes down?"_
- [ ] Answer: _"How would this behave under 10x load?"_
- [ ] Make a small change to the code without asking Copilot CLI

---

## 🎯 End Goal

After Phase 10, when an interviewer asks:

> _"Walk me through how your system handles a new order from placement to delivery"_

You close your laptop, pick up a marker, and draw the full flow on the whiteboard — Kafka topics, services, Redis GEO, RabbitMQ fan-out, AWS equivalents — from memory.

That's the goal.
