# Details

Date : 2026-03-19 00:41:12

Directory e:\\Github\\go-ledger-service

Total : 47 files,  6637 codes, 88 comments, 1105 blanks, all 7830 lines

[Summary](results.md) / Details / [Diff Summary](diff.md) / [Diff Details](diff-details.md)

## Files
| filename | language | code | comment | blank | total |
| :--- | :--- | ---: | ---: | ---: | ---: |
| [.github/workflows/ci.yml](/.github/workflows/ci.yml) | YAML | 72 | 0 | 21 | 93 |
| [Dockerfile](/Dockerfile) | Docker | 14 | 12 | 12 | 38 |
| [Go Ledger Service.postman\_collection.json](/Go%20Ledger%20Service.postman_collection.json) | JSON | 238 | 0 | 1 | 239 |
| [Makefile](/Makefile) | Makefile | 11 | 0 | 7 | 18 |
| [README.md](/README.md) | Markdown | 166 | 0 | 59 | 225 |
| [cmd/ledger-admin/main.go](/cmd/ledger-admin/main.go) | Go | 403 | 9 | 85 | 497 |
| [cmd/ledger-api/main.go](/cmd/ledger-api/main.go) | Go | 74 | 3 | 12 | 89 |
| [cmd/ledger-worker/main.go](/cmd/ledger-worker/main.go) | Go | 20 | 0 | 6 | 26 |
| [cmd/webhook-receiver/main.go](/cmd/webhook-receiver/main.go) | Go | 82 | 0 | 15 | 97 |
| [docker-compose.yml](/docker-compose.yml) | YAML | 146 | 4 | 8 | 158 |
| [docs/Go Take-Home Task.md](/docs/Go%20Take-Home%20Task.md) | Markdown | 145 | 0 | 55 | 200 |
| [go.mod](/go.mod) | Go Module File | 12 | 0 | 5 | 17 |
| [go.sum](/go.sum) | Go Checksum File | 16 | 0 | 1 | 17 |
| [internal/cache/redis.go](/internal/cache/redis.go) | Go | 34 | 2 | 11 | 47 |
| [internal/config/ledger.go](/internal/config/ledger.go) | Go | 168 | 0 | 22 | 190 |
| [internal/db/postgres.go](/internal/db/postgres.go) | Go | 55 | 0 | 14 | 69 |
| [internal/http/ledger\_api.go](/internal/http/ledger_api.go) | Go | 638 | 1 | 98 | 737 |
| [internal/http/request\_id.go](/internal/http/request_id.go) | Go | 36 | 7 | 10 | 53 |
| [internal/http/response.go](/internal/http/response.go) | Go | 32 | 2 | 6 | 40 |
| [internal/idempotency/redis\_reference\_store.go](/internal/idempotency/redis_reference_store.go) | Go | 205 | 8 | 37 | 250 |
| [internal/idempotency/redis\_reference\_store\_test.go](/internal/idempotency/redis_reference_store_test.go) | Go | 122 | 0 | 26 | 148 |
| [internal/ratelimiting/redis\_sliding\_window.go](/internal/ratelimiting/redis_sliding_window.go) | Go | 143 | 0 | 24 | 167 |
| [internal/ratelimiting/redis\_sliding\_window\_test.go](/internal/ratelimiting/redis_sliding_window_test.go) | Go | 112 | 0 | 22 | 134 |
| [internal/repository/ledger\_balance\_repository.go](/internal/repository/ledger_balance_repository.go) | Go | 44 | 0 | 13 | 57 |
| [internal/repository/ledger\_entry\_repository.go](/internal/repository/ledger_entry_repository.go) | Go | 94 | 0 | 20 | 114 |
| [internal/repository/ledger\_transaction\_repository.go](/internal/repository/ledger_transaction_repository.go) | Go | 374 | 2 | 48 | 424 |
| [internal/repository/tenant\_repository.go](/internal/repository/tenant_repository.go) | Go | 54 | 4 | 12 | 70 |
| [internal/service/ledger\_balance\_service.go](/internal/service/ledger_balance_service.go) | Go | 31 | 0 | 9 | 40 |
| [internal/service/ledger\_entry\_service.go](/internal/service/ledger_entry_service.go) | Go | 74 | 0 | 16 | 90 |
| [internal/service/ledger\_entry\_service\_test.go](/internal/service/ledger_entry_service_test.go) | Go | 173 | 0 | 16 | 189 |
| [internal/service/ledger\_transaction\_service.go](/internal/service/ledger_transaction_service.go) | Go | 189 | 3 | 34 | 226 |
| [internal/service/ledger\_transaction\_service\_test.go](/internal/service/ledger_transaction_service_test.go) | Go | 325 | 0 | 32 | 357 |
| [internal/service/tenant\_auth\_service.go](/internal/service/tenant_auth_service.go) | Go | 41 | 3 | 11 | 55 |
| [internal/service/tenant\_auth\_service\_test.go](/internal/service/tenant_auth_service_test.go) | Go | 95 | 0 | 17 | 112 |
| [internal/tenant/context.go](/internal/tenant/context.go) | Go | 25 | 4 | 7 | 36 |
| [internal/tenant/schema.go](/internal/tenant/schema.go) | Go | 6 | 1 | 4 | 11 |
| [internal/worker/runtime.go](/internal/worker/runtime.go) | Go | 209 | 2 | 40 | 251 |
| [internal/worker/transaction\_processor.go](/internal/worker/transaction_processor.go) | Go | 192 | 0 | 32 | 224 |
| [internal/worker/webhook\_processor.go](/internal/worker/webhook_processor.go) | Go | 189 | 0 | 33 | 222 |
| [migrations/0001\_init\_public.sql](/migrations/0001_init_public.sql) | MS SQL | 34 | 8 | 10 | 52 |
| [migrations/0002\_init\_tenant\_schema.sql](/migrations/0002_init_tenant_schema.sql) | MS SQL | 37 | 3 | 8 | 48 |
| [migrations/0003\_seed\_demo\_data.sql](/migrations/0003_seed_demo_data.sql) | MS SQL | 941 | 5 | 54 | 1,000 |
| [scripts/tests/concurrency.sh](/scripts/tests/concurrency.sh) | Shell Script | 103 | 1 | 20 | 124 |
| [scripts/tests/concurrency\_overdraw.sh](/scripts/tests/concurrency_overdraw.sh) | Shell Script | 129 | 1 | 30 | 160 |
| [scripts/tests/integration.sh](/scripts/tests/integration.sh) | Shell Script | 131 | 1 | 33 | 165 |
| [scripts/tests/lib.sh](/scripts/tests/lib.sh) | Shell Script | 178 | 1 | 41 | 220 |
| [scripts/tests/smoke.sh](/scripts/tests/smoke.sh) | Shell Script | 25 | 1 | 8 | 34 |

[Summary](results.md) / Details / [Diff Summary](diff.md) / [Diff Details](diff-details.md)