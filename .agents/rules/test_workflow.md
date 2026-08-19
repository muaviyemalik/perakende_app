---
name: Automatic Test Workflow
description: Tüm geliştirme görevlerinde standart olarak uygulanacak otomatik test iş akışı kuralı.
---

# Test Workflow Kuralı

Bundan sonraki her geliştirme görevinde, görevi tamamlamadan önce aşağıdaki test sırasını otomatik olarak uygula:

1. **Mevcut testleri çalıştır:** Geliştirmeye başlamadan önce mevcut test altyapısını (`npx supabase test db` vb.) çalıştır.
2. **Değişiklikten önce baseline sonucunu kaydet:** Test sonuçlarını baseline olarak not et.
3. **Değişikliği yap:** Gerekli kod/SQL değişikliklerini uygula.
4. **İlgili testleri çalıştır:** Yalnızca yapılan değişikliklerle ilgili (örneğin `00_complete_sale.test.sql`) testleri çalıştırarak değişikliği doğrula.
5. **Tüm regression testlerini çalıştır:** Sistemde bozulma (regression) olmadığını garanti altına almak için tüm test paketini baştan çalıştır.
6. **Hataları düzelt:** Eğer herhangi bir test başarısız (FAIL) olursa, problemi düzelt ve testleri tekrar çalıştır.
7. **PASS kuralı:** Testler tamamen PASS (başarılı) olmadan görevi hiçbir şekilde "tamamlandı" kabul etme. (Eğer test altyapısı lokal ortam yetersizliği (Docker eksikliği vb.) sebebiyle çalıştırılamıyorsa, bu durumu kullanıcıya açıkça belirt ve onayı bekle.)
8. **Raporlama:** Görev sonunda daima oluşturulan/çalıştırılan testleri, PASS/FAIL durumunu ve değiştirilen dosyaları Türkçe olarak kısa bir rapor halinde sun.
