---
title: "ACME Pricing SDK + CLI"
created: "2026-05-04"
approved_by: pending
status: draft
evidence_base:
  - file: "/Users/danny/Projects/superteam/superteam/examples/acme/pricing-sdk.py"
    description: "Mock pricing service with API contract, chaos modes, and StatsD endpoint"
---

## Goal

Build a Python SDK and CLI for the ACME internal pricing service that handles service flakiness through retry logic with exponential backoff+jitter, implements 60s LRU caching, emits structured metrics to DataDog StatsD, and provides typed error handling for unknown SKUs.

## Functional Requirements

### SDK Core Functionality

1. **SDK must provide a client class** that fetches pricing from `localhost:8080` via `GET /pricing/{sku}?region={region}` endpoint [evidence: pricing-sdk.py lines 270-324]

2. **SDK must retry failed requests** with exponential backoff+jitter for transient errors (503 Service Unavailable) [evidence: user request]

3. **SDK must cache responses** for 60 seconds with LRU eviction, maximum 1000 entries [evidence: user request, pricing-sdk.py line 318]

4. **SDK must emit metrics** to DataDog StatsD agent at `localhost:8125` with `pricing.cli.*` prefix [evidence: user request, pricing-sdk.py lines 100-138]

5. **SDK must emit structured logs** at INFO level [evidence: user request]

6. **SDK must raise typed `SKUNotFoundError`** when the service returns 404 for unknown SKUs [evidence: user request, pricing-sdk.py lines 300-309]

### CLI Functionality

7. **CLI must provide `acme price` command** that accepts SKU and region arguments [evidence: user request]

8. **CLI must output pricing information** in human-readable format [evidence: user request]

9. **CLI must surface structured errors** for unknown SKUs with clear messaging [evidence: user request]

### Metrics

10. **SDK must emit request count metrics** by status code (e.g., `pricing.cli.requests:1|c|#status:200`) [evidence: user request]

11. **SDK must emit latency metrics** (e.g., `pricing.cli.latency:42.7|h`) [evidence: user request]

12. **SDK must emit cache hit/miss metrics** (e.g., `pricing.cli.cache_hit:1|c`) [evidence: user request]

13. **SDK must emit retry count metrics** (e.g., `pricing.cli.retry_count:1|c`) [evidence: user request]

### Package Distribution

14. **Package must be installable via pip** using setuptools [evidence: user request]

15. **Package must support Python 3.12** [evidence: user request]

## Non-Functional Requirements

### Performance

16. **SDK must achieve p99 latency < 100ms** with warm cache under 1000-iteration stress test [evidence: user request]

17. **SDK must handle 0 unhandled exceptions** during 1000-iteration stress test [evidence: user request]

### Reliability

18. **SDK must successfully retry** through 10% random 503 errors from the pricing service [evidence: pricing-sdk.py lines 278-289]

19. **SDK must successfully handle** 5% random 200ms latency spikes from the pricing service [evidence: pricing-sdk.py lines 271-276]

### Observability

20. **Metrics must be visible** in DataDog after SDK execution [evidence: user request]

21. **Logs must be structured** and include relevant context (SKU, region, status, latency) [evidence: user request]

### Error Handling

22. **SDK must distinguish** between transient errors (retryable) and permanent errors (non-retryable) [evidence: user request]

23. **SDK must surface** service errors with clear, actionable messages [evidence: user request]

## Final Acceptance Gates

### Hard Gates

1. **Stress Test Gate**: Execute 1000-iteration stress test with 0 unhandled exceptions and p99 latency < 100ms with warm cache

2. **Metrics Gate**: Verify `pricing.cli.*` metrics appear in DataDog StatsD endpoint at `localhost:8080/admin/metrics`

3. **Error Handling Gate**: Verify unknown SKU (e.g., `INVALID-SKU`) raises `SKUNotFoundError` with structured error message

4. **Package Installation Gate**: Verify package installs cleanly via pip and `acme price` command is available

### Soft Gates

5. **Retry Behavior Gate**: Verify SDK successfully retries through 503 errors with exponential backoff+jitter

6. **Cache Behavior Gate**: Verify cache hits return within 60s window and LRU eviction works at 1000 entries

7. **Latency Spike Gate**: Verify SDK handles 200ms latency spikes without failure

## Evidence Base

### API Contract

**Source**: `/Users/danny/Projects/superteam/superteam/examples/acme/pricing-sdk.py`

**Pricing Endpoint** (lines 270-324):
- Method: `GET /pricing/{sku}?region={region}`
- Success Response (200):
  ```json
  {
    "sku": "SKU-1234",
    "region": "us-west-2",
    "price_usd": 12.34,
    "currency": "USD",
    "computed_at": "2026-05-04T12:34:56.789Z",
    "cache_ttl_seconds": 60
  }
  ```
- Error Response (404 - Unknown SKU):
  ```json
  {
    "error": "sku_not_found",
    "sku": "INVALID-SKU",
    "message": "no pricing record for SKU 'INVALID-SKU'"
  }
  ```
- Error Response (503 - Transient):
  ```json
  {
    "error": "backend_unavailable",
    "message": "transient — please retry"
  }
  ```
- Error Response (400 - Missing Region):
  ```json
  {
    "error": "missing_region",
    "message": "query param 'region' is required"
  }
  ```

**Chaos Modes** (lines 271-289):
- 10% random 503 errors
- 5% random 200ms latency spikes
- Unknown SKUs (not matching `SKU-\d+`) always return 404

**StatsD Endpoint** (lines 100-138):
- UDP listener on `localhost:8125`
- Format: `metric.name:value|type|@sample_rate|#tag1:val,tag2:val`
- Examples: `pricing.cli.requests:1|c|#region:us-west-2,status:200`

**Admin Metrics Endpoint** (lines 326-343):
- `GET /admin/metrics?name={name}&limit={limit}`
- Returns captured StatsD packets

### User Decisions

- Package name: `acme_pricing`
- CLI entry point: `acme`
- Python version: 3.12
- Cache size: 1000 entries
- Logging: INFO level, structured
- Retry configuration: SDK to determine reasonable defaults
- CLI output: human-readable
- Build tool: setuptools

## Constraints

1. **Must use standard Python libraries** where possible (no external dependencies unless necessary) [evidence: user request]

2. **Must not modify** the mock pricing service infrastructure [evidence: scope boundary]

3. **Must not implement** authentication or authorization (service requires none) [evidence: user request]

4. **Must not implement** persistent caching (cache is process-scoped only) [evidence: user request]

## Context

### Service Behavior

The ACME pricing service is a mock implementation that simulates production flakiness through deterministic chaos modes. The service is port-forwarded from production to `localhost:8080` for local development and testing.

### Chaos Modes

The service intentionally introduces failures to test SDK resilience:
- 10% of requests return 503 (transient backend errors)
- 5% of requests have +200ms latency spikes
- Unknown SKUs always return 404 with structured error

### Pricing Semantics

Price is deterministic per (sku, region):
```
price_usd = round(((hash(sku) * 31 + hash(region)) % 9000 + 100) / 100, 2)
```
Range: $1.00 to $90.99

### StatsD Integration

The mock infrastructure includes a StatsD UDP listener that captures metrics for verification via `/admin/metrics` endpoint.

## Assumptions

1. **Retry defaults**: SDK will use reasonable retry parameters (max 3 attempts, initial backoff 100ms, max backoff 1s, jitter 25%) [evidence: user request to "figure it out yourself"]

2. **Standard library availability**: Python 3.12 standard library includes all necessary modules (http.client, socket, logging, functools, time, random) [evidence: Python 3.12 stdlib]

3. **StatsD agent availability**: DataDog StatsD agent is running at `localhost:8125` during SDK execution [evidence: user request]

4. **Pricing service availability**: Pricing service is running at `localhost:8080` during SDK execution [evidence: user request]

## Open Questions

None.
