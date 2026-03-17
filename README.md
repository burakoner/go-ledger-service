# Go Ledger Service

## Servisi Çalıştırma

```bash
cp .env.example .env
docker compose up --build
```

Sağlık kontrolleri:

```bash
curl http://localhost:8080/api/v1/health
curl http://localhost:8081/api/v1/health
```

## Mimari Genel Bakış

Bu proje küçük bir servis ayrımı kullanır: `ledger-api` (çalışma zamanı transaction API), `ledger-admin` (tenant onboarding API) ve `ledger-worker` (asenkron worker süreci). Altyapı servisleri PostgreSQL (ana veri kaynağı), Redis (hızlı geçici kontrol katmanı) ve RabbitMQ’dur (API ile worker arasında mesaj taşıma). Kod yapısı `handler -> service -> repository` ayrımıyla düzenlenmiştir.

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

3. Asenkron işleme RabbitMQ + worker ile ayrıştırıldı.
- Artı: API, arka plan işleme sürerken daha hızlı yanıt verir.
- Eksi: kuyruk gözlemlenebilirliği, retry davranışı ve hata yönetimi açısından ek operasyonel yük getirir.

4. Idempotency ve rate limit kontrolleri PostgreSQL dışında Redis’te tutuldu.
- Artı: tekrar istek tespiti ve limit kontrolü daha hızlı ve basit olur.
- Eksi: kalıcılık (durability) beklentileri için ek strateji netleştirilmelidir.

## Sonraki İyileştirme Adımları

1. Admin API'nin tenant yaşam döngüsünü tam kapsaması (register, durum güncelleme, config güncelleme, listeleme/detay).
2. Tenant oluşturma ve API key üretim/rotasyon süreçlerinin ayrılması.
3. Kritik admin işlemlerine maker-checker tabanlı onay akışı eklenmesi.
4. Admin API güvenliğinin IP allowlist, MFA ve kısa ömürlü yetki belirteçleriyle güçlendirilmesi.
5. Eşzamanlılık ve tenant izolasyonuna odaklı integration test kapsamının genişletilmesi.
6. Webhook teslimatının production seviyesinde retry/backoff, outbox izleme ve dead-letter akışıyla tamamlanması.
7. Gözlemlenebilirlik katmanının structured log, metrik, trace ve alarm bileşenleriyle güçlendirilmesi.
8. Migration rollout sürecinin otomasyonla güvenli hale getirilmesi (sıralı çalıştırma, doğrulama, geri dönüş planı).
9. Ortam güvenlik kontrollerinin otomatikleştirilmesi (yanlış ortam koruması, zorunlu env/secrets doğrulaması).
