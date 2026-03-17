# Go Ledger Service

## Servisi Çalıştırma

```bash
cp .env.example .env
docker compose up --build
```

Sağlık kontrolleri:

```bash
curl http://localhost:8080/health
curl http://localhost:8081/health
```

## Mimari Genel Bakış

Bu proje küçük bir servis ayrımı kullanır: `ledger-api` (çalışma zamanı transaction API), `ledger-admin` (tenant onboarding API) ve `ledger-worker` (asenkron worker süreci). Altyapı servisleri PostgreSQL (ana veri kaynağı) ve Redis’tir (hızlı geçici kontrol katmanı). Asenkron transaction akışı için `pending` kayıtlar PostgreSQL üzerinde tutulur ve worker tarafından işlenir. Kod yapısı `handler -> service -> repository` ayrımıyla düzenlenmiştir.

## Schema-Per-Tenant İzolasyonu

Tenant metadata verileri ortak `public` şemasında tutulur (`tenant_accounts`, `tenant_api_keys`, `tenant_configs`, `tenant_webhook_outbox`). Her tenant için `tenant_<tenantidwithoutdashes>` formatında izole bir şema oluşturulur. Tenant çözümleme API key üzerinden yapılır ve tenant’a özel işlemler yalnızca ilgili tenant şemasında çalıştırılarak tenantlar arası veri erişimi engellenir.

## Redis Kullanımı (Neden ve Nerede)

Redis şu amaçlarla kullanılır:

- idempotency key kontrolü (TTL tabanlı tekrar oynatma penceresi)
- tenant bazlı rate limiting

Gerekçe: Redis düşük gecikmeli key kontrolü ve doğal süre sonu (expiration) desteği sağlar. Bu sayede idempotency ve rate limit mantığı daha basit ve hızlı uygulanır.

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

4. Idempotency ve rate limit kontrolleri PostgreSQL dışında Redis’te tutuldu.

- Artı: tekrar istek tespiti ve limit kontrolü daha hızlı ve basit olur.
- Eksi: kalıcılık (durability) beklentileri için ek strateji netleştirilmelidir.

## Sonraki İyileştirme Adımları

- Admin API'nin tenant yaşam döngüsünü tam kapsaması (register, durum güncelleme, config güncelleme, listeleme/detay).
- Tenant oluşturma ve API key üretim/rotasyon süreçlerinin ayrılması.
- Kritik admin işlemlerine maker-checker tabanlı onay akışı eklenmesi.
- Admin API güvenliğinin IP allowlist, MFA ve kısa ömürlü yetki belirteçleriyle güçlendirilmesi.
- Eşzamanlılık ve tenant izolasyonuna odaklı integration test kapsamının genişletilmesi.
- Webhook teslimatının production seviyesinde retry/backoff, outbox izleme ve dead-letter akışıyla tamamlanması.
- Gözlemlenebilirlik katmanının structured log, metrik, trace ve alarm bileşenleriyle güçlendirilmesi.
- Migration rollout sürecinin otomasyonla güvenli hale getirilmesi (sıralı çalıştırma, doğrulama, geri dönüş planı).
- Ortam güvenlik kontrollerinin otomatikleştirilmesi (yanlış ortam koruması, zorunlu env/secrets doğrulaması).
- Servis logları ve audit logları için uçtan uca bir loglama kurgusunun kurulması, audit kayıtlarının append-only/değiştirilemez yapıda tutulması ve merkezi toplama ile saklama/erişim politikalarının tanımlanması.
- Tenant durumu değişirken in-flight transaction yarışlarının (race) işlem öncesi son durum kontrolü ve test senaryolarıyla güvence altına alınması.
- Rate limiting katmanının uygulama içinden edge proxy seviyesine taşınması (örn. Nginx/Envoy/HAProxy), böylece uygulama üzerindeki yükün azaltılması ve tek noktadan güvenlik, yönlendirme, TLS, IP kısıtlama ve trafik politikalarının yönetilmesi.

## Notlar

- `ledger-api` ve `ledger-worker` tarafında `internal` katmanları aktif olarak kullanıldı. `ledger-admin` için aynı refactor teknik olarak uygun olsa da, mevcut task kapsamına onboarding dahil olmadığında bu servis bilinçli olarak daha sade bırakıldı.
