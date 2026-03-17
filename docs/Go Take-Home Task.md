# Go Take-Home Task: Multi-Tenant Payment

# Ledger Service

**Estimated Time:** 10-15 hours (1 week deadline)  
**Language:** Go 1.24+  
**Submission:** GitHub repository with README

## Overview

Build a **multi-tenant payment ledger service** that processes payment transactions asynchronously, maintains account balances per tenant, and exposes a REST API. The system should demonstrate clean architecture, safe concurrency, idempotent operations, and idiomatic Go practices.

You are building a backend service where multiple merchants (tenants) can submit payment transactions. Each merchant operates in a fully isolated PostgreSQL schema. Transactions are validated, processed asynchronously, and reflected in the merchant’s ledger with accurate balance tracking.

## Tech Stack

| Component        | Technology                               |
| ---------------- | ---------------------------------------- |
| Language         | Go 1.24+                                 |
| Database         | PostgreSQL (required)                    |
| Cache/Queue      | Redis (optional - use where you see fit) |
| Containerisation | Docker + docker-compose                  |

Redis is available if you find it useful for things like rate limiting, idempotency caching, queue management, or distributed locking. Its use is not mandatory - justify your choices in the README.

## Core Requirements

## 1. Multi-Tenant Architecture (Schema-Per-Tenant)

- Each merchant has: id, name, api_key, currency (GBP, EUR, USD), status (active/suspended)
- Requests are scoped to a merchant via an X-API-Key header
- A suspended merchant’s transactions must be rejected

**Schema-per-tenant isolation using PostgreSQL schemas:**

- Each merchant must have its own PostgreSQL schema (e.g., tenant\_<merchant_id>) containing its transactions, ledger entries, and balance data
- A shared public schema should hold tenant/merchant metadata (registry, API keys, configuration)
- There must be zero data leakage between tenants - one merchant must never access or affect another’s transactions, balances, or ledger entries
- Tenant resolution should happen early in the request lifecycle (middleware) and set the appropriate schema via search_path or equivalent mechanism
- New tenants should be onboardable without code changes - registering a new merchant should dynamically create their schema and tables (migrations)
- Schema creation and migrations should be handled programmatically

### 2. Transaction Processing

Each transaction has:

####

```json
{
  "reference": "unique-idempotency-key",
  "type": "credit" | "debit",
  "amount": 1500 ,
  "description": "Invoice #1042",
  "metadata": {}
}
```

**Rules:**

- Amounts are in minor units (e.g., 1500 = £15.00), must be positive integers
- Debit transactions must be rejected if the merchant’s available balance is insufficient
- Transactions go through states: pending → completed | failed

### 3. Idempotency

Idempotency is critical in payment systems. Implement a robust idempotency mechanism:

- The reference field acts as an idempotency key , unique per merchant
- If a transaction with the same reference is submitted again:
  - If the original is completed or pending → return the existing transaction (no duplicate processing)
  - The response must be identical to the original response
- Idempotency must hold under concurrent duplicate submissions (e.g., two identical requests arriving at the same time must not create two transactions)
- Include an Idempotency-Replayed: true header in responses that return a cached result
- Idempotency records should have a configurable TTL (e.g., 24 hours), after which the same reference can be reused

### 4. Async Processing Pipeline

Transactions must **not** be processed synchronously in the HTTP handler:

- The API accepts a transaction and returns 202 Accepted with a pending status
- A background worker pool picks up pending transactions from a queue
- Workers validate, apply balance changes, and update the transaction status to completed or failed
- Configurable number of workers via environment variable (WORKER_COUNT)
- Graceful shutdown: on SIGTERM/SIGINT, stop accepting new work, drain the queue, and finish all in-flight transactions before exiting

### 5. Balance & Ledger

- Each merchant has a running balance maintained in their isolated tenant schema
- Balance updates must be safe under concurrent access (multiple workers processing transactions for the same merchant simultaneously) - use appropriate PostgreSQL locking strategies (e.g., SELECT ... FOR UPDATE, advisory locks)
- Every balance change creates an immutable ledger entry with: timestamp, transaction reference, previous balance, new balance, and change amount

### 6. Rate Limiting

- Implement per-merchant rate limiting on transaction submission
- Use a token bucket or sliding window algorithm
- Configurable limits (e.g., RATE_LIMIT_PER_MINUTE=60)
- Return 429 Too Many Requests with a Retry-After header when exceeded

### 7. Webhook Notifications

- When a transaction reaches a terminal state (completed or failed), fire an async webhook callback
- Each merchant can have a configured webhook_url
- The webhook payload should include: transaction ID, reference, status, amount, and timestamp
- Implement basic retry logic (e.g., up to 3 attempts with exponential backoff)
- For this task, the webhook can target a local endpoint or simply log the payload - the mechanism and retry logic matter more than actual HTTP delivery

### 8. REST API

| Method | Endpoint                 | Description                                         |
| ------ | ------------------------ | --------------------------------------------------- |
| POST   | /api/v1/transactions     | Submit a new transaction (returns 202)              |
| GET    | /api/v1/transactions/:id | Get transaction status and details                  |
| GET    | /api/v1/transactions     | List transactions (paginated, filterable by status) |
| GET    | /api/v1/balance          | Get current merchant balance                        |
| GET    | /api/v1/ledger           | Get ledger entries (paginated)                      |
| GET    | /health                  | Health check (including DB connectivity)            |

All endpoints (except /health) must be authenticated and tenant-scoped.

**Error Response Format** (consistent across all endpoints):

```json
{
  "error": {
    "code": "INSUFFICIENT_BALANCE",
    "message": "Debit of 5000 exceeds available balance of 3200",
    "request_id": "uuid"
  }
}
```

## Technical Expectations

### Architecture

- Clean separation of concerns (handler → service → repository)
- Dependency injection via interfaces (not concrete types)
- Configuration via environment variables
- Project layout following standard Go conventions

### Database

- PostgreSQL with schema-per-tenant isolation
- Proper use of transactions for balance updates and ledger entries (atomic operations)
- Database migrations handled programmatically (tenant schema creation on registration)
- Connection pooling configured appropriately
- Indexes on frequently queried fields

### Concurrency

- Worker pool pattern for async processing
- Safe concurrent balance updates using appropriate DB-level locking
- Concurrent idempotency checks must be race-free
- Graceful shutdown with proper signal handling

### Testing

- Unit tests for core business logic (balance calculations, validation, idempotency)
- Concurrency tests (e.g., parallel debits must not overdraw, duplicate references under race conditions)
- Integration tests covering the full request lifecycle (use a test database or testcontainers)
- Table-driven tests where appropriate

### Containerisation

- Include a Dockerfile and docker-compose.yml with Go service, PostgreSQL, and Redis (if used)
- The service should be runnable with a single docker-compose up command
- Include seed data or a setup script that creates a couple of test merchants on startup

## Submission Guidelines

1. Push the code to a **GitHub repository** and share the repo link with us (please add us as collaborators if the repository is private).
2. Include a README.md with:

- How to run the service (docker-compose up)
- Architecture overview (a short paragraph or simple diagram)
- How schema-per-tenant isolation is implemented
- Why you chose to use (or not use) Redis and where
- Design decisions and trade-offs you made
- What you’d improve or change with more time

3. Commit history should reflect your development process (don’t squash into one commit)

## Evaluation Criteria

| Area            | What We’re Looking For                                                             |
| --------------- | ---------------------------------------------------------------------------------- |
| Multi-Tenancy   | Proper schema-per-tenant in PostgreSQL, zero data leakage, clean tenant resolution |
| Idempotency     | Race-free duplicate handling, correct cached responses, TTL behaviour              |
| Concurrency     | Safe use of goroutines, DB-level locking, no race conditions                       |
| Database Design | Schema structure, migrations, indexing, atomic operations, connection management   |
| Architecture    | Clean layers, separation of concerns, interface-driven design                      |
| Correctness     | Balance integrity, proper state transitions, edge case handling                    |
| Go Idioms       | Error handling, naming conventions, project layout, effective use of stdlib        |
| Testing         | Meaningful coverage including concurrency edge cases and integration tests         |
| Code Quality    | Readability, consistency, documentation where needed                               |

We value **clarity and correctness over cleverness**. A well-structured, well-tested solution is always
preferred over a rushed implementation.
