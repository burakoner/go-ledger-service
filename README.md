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
bash scripts/tests/concurrency_overdraw.sh
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
bash scripts/tests/concurrency_overdraw.sh
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

Bu tablo değerleri `migrations/0003_seed_demo_data.sql` dosyasındaki terminal (`completed` / `failed`) transaction verilerine göre hesaplanmıştır; seed içinde `pending` kayıt bırakılmamıştır.

| Tenant Code | Tenant Name     | Currency | Tenant Status | API Key                                      | API Key Status | Webhook URL                                          | Transaction Rows | Ledger Entry Rows | Balance |
| ----------- | --------------- | -------- | ------------- | -------------------------------------------- | -------------- | ---------------------------------------------------- | ---------------- | ----------------- | ------- |
| `alpha`     | Alpha Market    | USD      | active        | `TK_SeedAlphaA1B2C3D4E5F6G7H8J9K0L1M2N3`     | active         | `http://webhook-receiver:8088/webhooks/transactions` | 20               | 17                | 26030   |
| `beta`      | Beta Store      | EUR      | active        | `TK_SeedBetaB1C2D3E4F5G6H7J8K9L0M1N2P3`      | revoked        | `--`                                                 | 0                | 0                 | 0       |
| `gamma`     | Gamma Shop      | GBP      | suspended     | `TK_SeedGammaC1D2E3F4G5H6J7K8L9M0N1P2Q3`     | active         | `http://webhook-receiver:8088/webhooks/transactions` | 7                | 5                 | 4784    |
| `delta`     | Delta Bazaar    | USD      | active        | `TK_SeedDeltaD1E2F3G4H5J6K7L8M9N0P1Q2R3`     | active         | `--`                                                 | 13               | 11                | 11042   |
| `epsilon`   | Epsilon Trade   | EUR      | active        | `TK_SeedEpsilonE1F2G3H4J5K6L7M8N9P0Q1R2S3`   | active         | `http://webhook-receiver:8088/webhooks/transactions` | 15               | 12                | 14091   |
| `zeta`      | Zeta Commerce   | GBP      | active        | `TK_SeedZetaF1G2H3J4K5L6M7N8P9Q0R1S2T3U4`    | active         | `--`                                                 | 24               | 21                | 31756   |
| `eta`       | Eta Supplies    | USD      | active        | `TK_SeedEtaG1H2J3K4L5M6N7P8Q9R0S1T2U3V4W5`   | active         | `http://webhook-receiver:8088/webhooks/transactions` | 40               | 36                | 47768   |
| `theta`     | Theta Retail    | EUR      | active        | `TK_SeedThetaH1J2K3L4M5N6P7Q8R9S0T1U2V3W4X5` | revoked        | `--`                                                 | 64               | 59                | 77578   |
| `iota`      | Iota Outlet     | GBP      | active        | `TK_SeedIotaJ1K2L3M4N5P6Q7R8S9T0U1V2W3X4Y5`  | active         | `http://webhook-receiver:8088/webhooks/transactions` | 72               | 67                | 90838   |
| `kappa`     | Kappa Wholesale | USD      | active        | `TK_SeedKappaK1L2M3N4P5Q6R7S8T9U0V1W2X3Y4Z5` | active         | `--`                                                 | 100              | 94                | 134726  |

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

- Ledger için ana veri kaynağı PostgreSQL seçildi.
  - Artı: bakiye ve ledger bütünlüğü için güçlü transaction tutarlılığı sağlar.
  - Eksi: SQL transaction ve kilitleme tasarımının daha dikkatli yapılması gerekir.

- Paylaşımlı satır yerine schema-per-tenant izolasyonu tercih edildi.
  - Artı: daha güçlü mantıksal izolasyon sınırı sağlar.
  - Eksi: dinamik şema oluşturma ve migration orkestrasyonu daha karmaşık hale gelir.

- Asenkron işleme PostgreSQL `pending` queue + worker ile ayrıştırıldı.
  - Artı: ek broker bağımlılığı olmadan API ve worker ayrımı korunur.
  - Eksi: yüksek tenant sayısında worker tarama stratejisi dikkatli tasarlanmalıdır.

- Idempotency ve rate limiting kontrolleri PostgreSQL dışında Redis’te tutuldu.
  - Artı: tekrar istek tespiti ve tenant bazlı limit kontrolü düşük gecikmeyle yapılır.
  - Eksi: kalıcılık (durability) beklentileri için ek strateji netleştirilmelidir.

## Sonraki İyileştirme Adımları

Bu çalışma bir home task kapsamında hazırlandığı için bazı konular bilinçli olarak sade tutuldu; üretim ortamında kullanılacak bir sürümde aşağıdaki geliştirmelerin uygulanması faydalı olur.

- İstek başlıklarına `timestamp` ve `receive window` alanlarının eklenmesi; sunucuda zaman kayması toleransına göre süresi geçmiş veya replay riski taşıyan isteklerin reddedilmesi.
- Transaction `POST` çağrıları için imza doğrulama (örn. HMAC) katmanının eklenmesi; imza hesaplamasında `http method`, `path`, `request body` ve `timestamp` bilgisinin zorunlu tutulması.
- Admin API güvenliğinin IP allowlist, MFA ve kısa ömürlü yetki belirteçleriyle güçlendirilmesi.
- Kritik admin işlemlerine maker-checker tabanlı onay akışı eklenmesi.
- Tenant oluşturma ve API key üretim/rotasyon süreçlerinin ayrılması.
- Admin API'nin tenant yaşam döngüsünü tam kapsaması (register, durum güncelleme, config güncelleme, listeleme/detay).
- Tenant durumu değişirken in-flight transaction yarışlarının (race) işlem öncesi son durum kontrolü ve test senaryolarıyla güvence altına alınması.
- Ledger kayıtlarının değişmezliğini teknik olarak garanti altına almak için append-only modelin kriptografik zincirleme (hash-chain / blockchain benzeri) yaklaşımla güçlendirilmesi.
- Webhook teslimatının queue/outbox tabanlı retry/backoff ve dead-letter akışıyla daha dayanıklı hale getirilmesi.
- Servis logları ve audit logları için uçtan uca bir loglama kurgusunun kurulması, audit kayıtlarının append-only/değiştirilemez yapıda tutulması ve merkezi toplama ile saklama/erişim politikalarının tanımlanması.
- Gözlemlenebilirlik katmanının structured log, metrik, trace ve alarm bileşenleriyle güçlendirilmesi.
- Rate limiting katmanının uygulama içinden edge proxy seviyesine taşınması (örn. Nginx/Envoy/HAProxy), böylece uygulama üzerindeki yükün azaltılması ve tek noktadan güvenlik, yönlendirme, TLS, IP kısıtlama ve trafik politikalarının yönetilmesi.
- Migration rollout sürecinin otomasyonla güvenli hale getirilmesi (sıralı çalıştırma, doğrulama, geri dönüş planı).
- Ortam güvenlik kontrollerinin otomatikleştirilmesi (yanlış ortam koruması, zorunlu env/secrets doğrulaması).
- Eşzamanlılık ve tenant izolasyonuna odaklı integration test kapsamının genişletilmesi.

## Notlar

- `ledger-api` ve `ledger-worker` tarafında `internal` katmanları aktif olarak kullanıldı. `ledger-admin` için aynı refactor teknik olarak mümkün olsa da, task kapsamına odaklanmak için bu servis bilinçli olarak daha sade tutuldu ve `internal` katmanına taşınmadı.

## Code Counter

### Languages

| language         | files |  code | comment | blank | total |
| :--------------- | ----: | ----: | ------: | ----: | ----: |
| Go               |    30 | 4,245 |      51 |   735 | 5,031 |
| MS SQL           |     3 | 1,012 |      16 |    72 | 1,100 |
| Shell Script     |     5 |   566 |       5 |   132 |   703 |
| Markdown         |     2 |   271 |       0 |   113 |   384 |
| JSON             |     1 |   238 |       0 |     1 |   239 |
| YAML             |     1 |   146 |       4 |     8 |   158 |
| Go Checksum File |     1 |    16 |       0 |     1 |    17 |
| Docker           |     1 |    14 |      12 |    12 |    38 |
| Go Module File   |     1 |    12 |       0 |     5 |    17 |
| Makefile         |     1 |    11 |       0 |     7 |    18 |

### Directories

| path                   | files |  code | comment | blank | total |
| :--------------------- | ----: | ----: | ------: | ----: | ----: |
| .                      |    46 | 6,531 |      88 | 1,086 | 7,705 |
| . (Files)              |     7 |   563 |      16 |    92 |   671 |
| cmd                    |     4 |   579 |      12 |   118 |   709 |
| cmd\\ledger-admin      |     1 |   403 |       9 |    85 |   497 |
| cmd\\ledger-api        |     1 |    74 |       3 |    12 |    89 |
| cmd\\ledger-worker     |     1 |    20 |       0 |     6 |    26 |
| cmd\\webhook-receiver  |     1 |    82 |       0 |    15 |    97 |
| docs                   |     1 |   145 |       0 |    55 |   200 |
| internal               |    26 | 3,666 |      39 |   617 | 4,322 |
| internal\\cache        |     1 |    34 |       2 |    11 |    47 |
| internal\\config       |     1 |   168 |       0 |    22 |   190 |
| internal\\db           |     1 |    55 |       0 |    14 |    69 |
| internal\\http         |     3 |   706 |      10 |   114 |   830 |
| internal\\idempotency  |     2 |   327 |       8 |    63 |   398 |
| internal\\ratelimiting |     2 |   255 |       0 |    46 |   301 |
| internal\\repository   |     4 |   566 |       6 |    94 |   666 |
| internal\\service      |     7 |   928 |       6 |   135 | 1,069 |
| internal\\tenant       |     2 |    31 |       5 |    12 |    48 |
| internal\\worker       |     3 |   596 |       2 |   106 |   704 |
| migrations             |     3 | 1,012 |      16 |    72 | 1,100 |
| scripts                |     5 |   566 |       5 |   132 |   703 |
| scripts\\tests         |     5 |   566 |       5 |   132 |   703 |
