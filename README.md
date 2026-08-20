# 🛒 Perakende POS

Modern, güvenli ve **offline-first** mimariyle geliştirilmiş bir perakende satış ve stok yönetim uygulaması.

Perakende POS; mağaza çalışanlarının günlük satış işlemlerini hızlı bir şekilde gerçekleştirmesini, ürün ve stok takibini kolaylaştırmasını ve yöneticilerin işletme verilerini merkezi bir panel üzerinden yönetmesini amaçlar.

## ✨ Öne Çıkan Özellikler

### 🔐 Güvenli Kullanıcı Yönetimi

- E-posta ve şifre ile güvenli giriş
- Admin ve çalışan rollerine göre farklı yetkiler
- İşletme bazlı tenant izolasyonu
- Supabase Row Level Security (RLS) ile veri güvenliği
- Yetkisiz kullanıcıların başka işletmelerin verilerine erişmesinin engellenmesi

### 🏪 Admin Paneli

Yöneticiler işletmenin genel durumunu tek ekrandan takip edebilir.

- 📦 Toplam ürün sayısı
- ⚠️ Kritik stok takibi
- 💰 Satış ve işletme verilerinin takibi
- 👥 Çalışan yönetimi
- 🛍️ Ürün yönetimi
- Ürün ekleme, düzenleme ve silme
- Barkod yönetimi
- Stok ve fiyat güncelleme

### 🛍️ Hızlı Satış Sistemi

POS ekranı günlük satış işlemlerini mümkün olduğunca hızlı ve pratik hale getirmek için tasarlanmıştır.

- 🔎 Barkod ile ürün arama
- ⌨️ Manuel ürün arama
- 🛒 Sepete ürün ekleme
- ➕➖ Ürün miktarı değiştirme
- ✏️ Manuel miktar girişi
- 📦 Stok kontrolü
- Satış sırasında stok miktarının kontrol edilmesi
- Sepetteki ürünlerin kolayca düzenlenebilmesi

### 📦 Akıllı Stok Yönetimi

Ürünlerin stok durumları gerçek veriler üzerinden takip edilir.

- Mevcut stok miktarını görüntüleme
- Kritik stok ürünlerini takip etme
- Satış sonrasında stokların güncellenmesi
- Stok yetersiz olduğunda satışın kontrol edilmesi
- Barkod bazlı ürün yönetimi
- Aynı işletmede aktif ürünlerde duplicate barkodların veritabanı seviyesinde engellenmesi

### 📡 Offline-First Çalışma

Uygulamanın önemli özelliklerinden biri internet bağlantısına mümkün olduğunca bağımlı olmamasıdır.

İnternet bağlantısı kesildiğinde:

- Ürün verileri cihazdaki yerel SQLite veritabanından kullanılabilir.
- Ürün ekleme işlemleri lokal olarak gerçekleştirilebilir.
- Ürün güncelleme işlemleri lokal olarak gerçekleştirilebilir.
- Ürün silme işlemleri soft-delete olarak lokal şekilde kaydedilebilir.
- Yapılan değişiklikler güvenli bir mutasyon kuyruğuna alınır.
- İnternet tekrar geldiğinde değişiklikler otomatik olarak sunucuya senkronize edilir.

Bu sayede kısa süreli internet kesintileri satış ve stok yönetiminin tamamen durmasına neden olmaz.

### 🔄 Güvenli Senkronizasyon

Offline yapılan değişikliklerin Supabase'e aktarılması için özel bir senkronizasyon sistemi kullanılmaktadır.

- FIFO mutation queue
- Otomatik retry
- Idempotency desteği
- Geçici ağ hatalarında tekrar deneme
- Kalıcı hatalarda Dead Letter mekanizması
- Tenant bazlı senkronizasyon
- Sunucu ve cihaz arasındaki veri tutarlılığının korunması

### 🛡️ Optimistic Concurrency Control

Bir ürün aynı anda birden fazla cihaz veya kullanıcı tarafından değiştirilirse sistem değişikliklerin sessizce birbirinin üzerine yazılmasına izin vermez.

Örneğin:

> Yönetici A ürünün fiyatını 100 TL → 120 TL yaparken, Yönetici B aynı ürünün eski verisi üzerinden 100 TL → 150 TL değişikliği yaparsa sistem bu durumu tespit eder.

Böylece **"son yazan kazanır" yaklaşımından kaynaklanan sessiz veri kayıpları önlenir.**

Çakışma tespit edildiğinde işlem güvenli şekilde durdurulur ve manuel çözüm gerektiren duruma alınır.

### 🗑️ Soft Delete

Ürünler doğrudan fiziksel olarak silinmek yerine soft-delete yaklaşımıyla yönetilir.

Bu yaklaşım:

- Veri kaybı riskini azaltır.
- Senkronizasyon sırasında silinen ürünlerin takip edilmesini sağlar.
- Eski kayıtların gerektiğinde incelenmesine olanak sağlar.
- Barkodların güvenli şekilde yeniden kullanılabilmesini sağlar.

### 🔒 Veri Bütünlüğü

Veritabanı seviyesinde önemli bütünlük kontrolleri uygulanmaktadır.

- Tenant bazlı veri izolasyonu
- Partial Unique Index
- Duplicate barkod kontrolü
- Soft-delete desteği
- `updated_at` otomatik güncelleme
- Transaction tabanlı lokal işlemler
- SQLite mutation queue
- Supabase RLS
- Idempotent mutation işlemleri
- OCC tabanlı conflict detection

## 🏗️ Teknik Mimari

Proje modern bir Flutter + Supabase mimarisi üzerine kurulmuştur.

### Frontend

- Flutter
- Dart
- Provider
- SQLite
- SharedPreferences
- Connectivity Plus

### Backend

- Supabase
- PostgreSQL
- Row Level Security (RLS)
- PostgreSQL RPC
- Database Triggers
- Partial Indexes

### Offline Architecture

```text
                 ┌─────────────────────┐
                 │      Flutter UI     │
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │    Local Product    │
                 │        DAO          │
                 └──────────┬──────────┘
                            │
                    ┌───────▼────────┐
                    │     SQLite     │
                    │                │
                    │ Products       │
                    │ Mutations      │
                    └───────┬────────┘
                            │
                     Network Available
                            │
                            ▼
                 ┌─────────────────────┐
                 │ Mutation Sync Engine│
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │      Supabase       │
                 │                     │
                 │ PostgreSQL + RLS    │
                 │ Secure RPC          │
                 └─────────────────────┘
🧪 Test Durumu
Offline Product Mutations sistemi için kapsamlı testler bulunmaktadır.
Mevcut test paketi:
- ✅ Offline Create
- ✅ Offline Update
- ✅ Offline Delete
- ✅ Transaction Rollback
- ✅ FIFO Mutation Queue
- ✅ Retry mekanizması
- ✅ Dead Letter mekanizması
- ✅ Read-Sync overwrite koruması
- ✅ Idempotency
- ✅ OCC conflict detection
- ✅ Tenant isolation
- ✅ Logout sonrası mutation temizliği
- ✅ SQLite migration
- ✅ Supabase RPC mimarisi
Son doğrulamada:
57 / 57 test başarılı.
Tests: 57
Passed: 57
Failed: 0
Skipped: 0
🚀 Projenin Amacı
Perakende POS'un temel amacı yalnızca satış yapmak değil; güvenilir, hızlı ve internet bağlantısına dayanıklı bir mağaza yönetim altyapısı oluşturmak.
Özellikle fiziksel mağazalarda internet bağlantısının kesilmesi, birden fazla cihazın aynı veriyi değiştirmesi veya stok bilgilerinin farklı cihazlarda eş zamanlı güncellenmesi gibi gerçek dünya problemlerine karşı dayanıklı olacak şekilde tasarlanmıştır.
📌 Proje Durumu
🟢 Aktif geliştirme aşamasında

Temel POS, stok yönetimi, kullanıcı rolleri, Supabase entegrasyonu ve Offline Product Mutations altyapısı tamamlanmıştır.
Yeni özellikler ve iyileştirmeler geliştirmeye devam edilmektedir.
🧰 Kullanılan Teknolojiler
Teknoloji	Kullanım Alanı
Flutter	Mobil uygulama
Dart	Uygulama geliştirme
Supabase	Backend & Authentication
PostgreSQL	Veritabanı
SQLite	Offline veri
Provider	State management
RLS	Veri güvenliği
RPC	Güvenli server-side işlemler
Git	Versiyon kontrolü
GitHub	Kaynak kod yönetimi


👨‍💻 Geliştirici
Muaviye Malik
Bu proje; modern mobil uygulama geliştirme, offline-first mimari, veritabanı güvenliği, stok yönetimi ve gerçek dünya POS senaryolarını deneyimlemek amacıyla geliştirilmektedir.
```