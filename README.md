# Go Ledger Service

## Servisi Çalıştırma

```bash
cp .env.example .env
docker compose up -d --build
```

Sağlık kontrolleri:

```bash
curl http://localhost:8080/health
curl http://localhost:8090/health
curl http://localhost:8088/health
```

## Hızlı API Testi (Postman)

`Go Ledger Service.postman_collection.json` dosyası Postman'e import edilerek endpointler hızlıca test edilebilir.

## Test Scriptlerini Çalıştırma (Linux / Windows WSL)

### Linux

```bash
cd /path/to/go-ledger-service
bash scripts/tests/smoke.sh
bash scripts/tests/integration.sh
bash scripts/tests/concurrency.sh
```

`make` ile toplu çalıştırma:

```bash
sudo apt update && sudo apt install -y make
make test-all
```

Seed verisini zorunlu kontrol etmek için:

```bash
EXPECT_SEED_DATA=1 bash scripts/tests/smoke.sh
```

### Windows (WSL)

1. Docker Desktop'ta `Use the WSL 2 based engine` açık olmalıdır.
2. `Settings > Resources > WSL Integration` altında kullandığın distro aktif olmalıdır.
3. WSL terminalinde proje dizinine geç:

```bash
cd /mnt/e/Github/go-ledger-service
```

4. Testleri WSL içinde çalıştır:

```bash
bash scripts/tests/smoke.sh
bash scripts/tests/integration.sh
bash scripts/tests/concurrency.sh
```

5. `make` ile çalıştırmak istersen:

```bash
sudo apt update && sudo apt install -y make
make test-all
```

6. Seed verisini zorunlu kontrol etmek istersen:

```bash
EXPECT_SEED_DATA=1 bash scripts/tests/smoke.sh
```

PowerShell'den tek komutla WSL üzerinden çalıştırma:

```powershell
wsl -d Ubuntu -e bash -lc "cd /mnt/e/Github/go-ledger-service && make test-all"
```

## Seed/Test Veri Mekanizması

`docker compose up` ile PostgreSQL ilk kez ayağa kalkarken aşağıdaki migration dosyaları otomatik çalışır:

- `migrations/0001_init_public.sql`
- `migrations/0003_seed_demo_data.sql`

Bu seed mekanizması 10 örnek tenant oluşturur; tenant başına 0-100 arası transaction üretir (özellikle 0, 7, 13, 15 gibi düşük hacim senaryoları da dahil). Tenantların bir kısmında webhook aktiftir, bir kısmında kapalıdır ve en az bir tenant `suspended` durumdadır.

Seed tekrar çalıştırılmak istenirse PostgreSQL volume temizlenmelidir:

```bash
docker compose down -v
docker compose up --build
```

## Yerel Geliştirme Anahtarları

- Admin API anahtarı (`X-Admin-Key`): `WX5TczRsQnCk7k8k9AXbsW5czRsQnCkg`
- Webhook endpoint (compose içi servis adı ile): `http://webhook-receiver:8088/webhooks/transactions`

## Seed Tenant Listesi

| Tenant Code | Tenant Name     | Currency | Tenant Status | API Key                                      | API Key Status | Webhook URL                                          | Transaction Rows | Ledger Entry Rows | Balance |
| ----------- | --------------- | -------- | ------------- | -------------------------------------------- | -------------- | ---------------------------------------------------- | ---------------- | ----------------- | ------- |
| `alpha`     | Alpha Market    | USD      | active        | `TK_SeedAlphaA1B2C3D4E5F6G7H8J9K0L1M2N3`     | active         | `http://webhook-receiver:8088/webhooks/transactions` | 20               | 16                | 24560   |
| `beta`      | Beta Store      | EUR      | active        | `TK_SeedBetaB1C2D3E4F5G6H7J8K9L0M1N2P3`      | revoked        | `--`                                                 | 0                | 0                 | 0       |
| `gamma`     | Gamma Shop      | GBP      | suspended     | `TK_SeedGammaC1D2E3F4G5H6J7K8L9M0N1P2Q3`     | active         | `http://webhook-receiver:8088/webhooks/transactions` | 7                | 5                 | 4784    |
| `delta`     | Delta Bazaar    | USD      | active        | `TK_SeedDeltaD1E2F3G4H5J6K7L8M9N0P1Q2R3`     | active         | `--`                                                 | 13               | 10                | 9572    |
| `epsilon`   | Epsilon Trade   | EUR      | active        | `TK_SeedEpsilonE1F2G3H4J5K6L7M8N9P0Q1R2S3`   | active         | `http://webhook-receiver:8088/webhooks/transactions` | 15               | 11                | 12621   |
| `zeta`      | Zeta Commerce   | GBP      | active        | `TK_SeedZetaF1G2H3J4K5L6M7N8P9Q0R1S2T3U4`    | active         | `--`                                                 | 24               | 20                | 30286   |
| `eta`       | Eta Supplies    | USD      | active        | `TK_SeedEtaG1H2J3K4L5M6N7P8Q9R0S1T2U3V4W5`   | active         | `http://webhook-receiver:8088/webhooks/transactions` | 40               | 34                | 46823   |
| `theta`     | Theta Retail    | EUR      | active        | `TK_SeedThetaH1J2K3L4M5N6P7Q8R9S0T1U2V3W4X5` | revoked        | `--`                                                 | 64               | 56                | 76083   |
| `iota`      | Iota Outlet     | GBP      | active        | `TK_SeedIotaJ1K2L3M4N5P6Q7R8S9T0U1V2W3X4Y5`  | active         | `http://webhook-receiver:8088/webhooks/transactions` | 72               | 64                | 89343   |
| `kappa`     | Kappa Wholesale | USD      | active        | `TK_SeedKappaK1L2M3N4P5Q6R7S8T9U0V1W2X3Y4Z5` | active         | `--`                                                 | 100              | 90                | 133806  |

## Mimari Genel Bakış

Bu proje küçük bir servis ayrımı kullanır: `ledger-api` (çalışma zamanı transaction API), `ledger-admin` (tenant onboarding API) ve `ledger-worker` (asenkron worker süreci). Altyapı servisleri PostgreSQL (ana veri kaynağı) ve Redis’tir (hızlı geçici kontrol katmanı). Asenkron transaction akışı için `pending` kayıtlar PostgreSQL üzerinde tutulur ve worker tarafından işlenir. Kod yapısı `handler -> service -> repository` ayrımıyla düzenlenmiştir.

## Schema-Per-Tenant İzolasyonu

Tenant metadata verileri ortak `public` şemasında tutulur (`tenant_accounts`, `tenant_api_keys`, `tenant_configs`). Her tenant için `tenant_<tenantidwithoutdashes>` formatında izole bir şema oluşturulur. Tenant çözümleme API key üzerinden yapılır ve tenant’a özel işlemler yalnızca ilgili tenant şemasında çalıştırılarak tenantlar arası veri erişimi engellenir.

## Redis Kullanımı (Neden ve Nerede)

Redis şu amaçlarla kullanılır:

- idempotency key kontrolü (TTL tabanlı tekrar oynatma penceresi)
- tenant bazlı rate limiting kontrolü

Gerekçe: Redis düşük gecikmeli key kontrolü ve doğal süre sonu (expiration) desteği sağlar. Bu sayede idempotency ve rate limiting mantığı hızlı ve basit şekilde uygulanır.

## Tasarım Kararları ve Trade-Off'lar

1. Ledger için ana veri kaynağı PostgreSQL seçildi.

- Artı: bakiye ve ledger bütünlüğü için güçlü transaction tutarlılığı sağlar.
- Eksi: SQL transaction ve kilitleme tasarımının daha dikkatli yapılması gerekir.

2. Paylaşımlı satır yerine schema-per-tenant izolasyonu tercih edildi.

- Artı: daha güçlü mantıksal izolasyon sınırı sağlar.
- Eksi: dinamik şema oluşturma ve migration orkestrasyonu daha karmaşık hale gelir.

3. Asenkron işleme PostgreSQL `pending` queue + worker ile ayrıştırıldı.

- Artı: ek broker bağımlılığı olmadan API ve worker ayrımı korunur.
- Eksi: yüksek tenant sayısında worker tarama stratejisi dikkatli tasarlanmalıdır.

4. Idempotency ve rate limiting kontrolleri PostgreSQL dışında Redis’te tutuldu.

- Artı: tekrar istek tespiti ve tenant bazlı limit kontrolü düşük gecikmeyle yapılır.
- Eksi: kalıcılık (durability) beklentileri için ek strateji netleştirilmelidir.

## Sonraki İyileştirme Adımları

- Admin API'nin tenant yaşam döngüsünü tam kapsaması (register, durum güncelleme, config güncelleme, listeleme/detay).
- Tenant oluşturma ve API key üretim/rotasyon süreçlerinin ayrılması.
- Kritik admin işlemlerine maker-checker tabanlı onay akışı eklenmesi.
- Admin API güvenliğinin IP allowlist, MFA ve kısa ömürlü yetki belirteçleriyle güçlendirilmesi.
- Eşzamanlılık ve tenant izolasyonuna odaklı integration test kapsamının genişletilmesi.
- Webhook teslimatının queue/outbox tabanlı retry/backoff ve dead-letter akışıyla daha dayanıklı hale getirilmesi.
- Gözlemlenebilirlik katmanının structured log, metrik, trace ve alarm bileşenleriyle güçlendirilmesi.
- Migration rollout sürecinin otomasyonla güvenli hale getirilmesi (sıralı çalıştırma, doğrulama, geri dönüş planı).
- Ortam güvenlik kontrollerinin otomatikleştirilmesi (yanlış ortam koruması, zorunlu env/secrets doğrulaması).
- Servis logları ve audit logları için uçtan uca bir loglama kurgusunun kurulması, audit kayıtlarının append-only/değiştirilemez yapıda tutulması ve merkezi toplama ile saklama/erişim politikalarının tanımlanması.
- Tenant durumu değişirken in-flight transaction yarışlarının (race) işlem öncesi son durum kontrolü ve test senaryolarıyla güvence altına alınması.
- Rate limiting katmanının uygulama içinden edge proxy seviyesine taşınması (örn. Nginx/Envoy/HAProxy), böylece uygulama üzerindeki yükün azaltılması ve tek noktadan güvenlik, yönlendirme, TLS, IP kısıtlama ve trafik politikalarının yönetilmesi.
- İstek başlıklarına `timestamp` ve `receive window` alanlarının eklenmesi; sunucuda zaman kayması toleransı kontrolüyle süresi geçmiş/tekrar oynatılabilir isteklerin reddedilmesi.
- Transaction `POST` çağrıları için imza doğrulama (örn. HMAC) mekanizmasının eklenmesi; imza hesaplamasında `http method`, `path`, `request body` ve `timestamp` bilgisinin zorunlu tutulması.

## Notlar

- `ledger-api` ve `ledger-worker` tarafında `internal` katmanları aktif olarak kullanıldı. `ledger-admin` için aynı refactor teknik olarak mümkün olsa da, task kapsamına odaklanmak için bu servis bilinçli olarak daha sade tutuldu ve `internal` katmanına taşınmadı.
