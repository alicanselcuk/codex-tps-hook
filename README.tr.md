# Codex TPS Hook

Codex yanıtı tamamlanınca üretim hızı, gecikme, token/cache kullanımı ve tahmini API token maliyetini gösteren yerel `Stop` hook’u.

[English README](README.md) · [Codex yönergeleri](AGENTS.md) · [Özelleştirme](docs/customization.md) · [MIT lisansı](LICENSE)

```text
⚡ Decode≈ 50.0 · TPS≈ 35.7
⏱ İlk üretim≈ 2.0s · İlk metin≈ 3.1s
Σ Token · Input 1.000 · Output 250 (Reasoning 100)
↻ Cache 800 · Hit 80.0%
💵 API/son çağrı · gpt-6.1-sol · Standard≈ $0.0030 · Fast≈ $0.0060
```

Örnek değerler sentetik bir yanıttan gelir. Bütün satırlar **son kaydedilen model çağrısına** aittir. Görevin veya sohbetin toplamı değildir; bir kullanıcı mesajı çok sayıda model ve araç çağrısı içerebilir.

## Kurulum

Gerekenler:

- `Stop` komut hook’unu destekleyen, yerel JSONL oturum kaydında `token_usage_record` üreten Codex CLI/Desktop. Windows üzerinde Codex CLI **0.162.1** ve PowerShell **7.6.6** ile yerel doğrulama yapıldı. Eski/farklı kayıt biçimlerinde metrik çıkmayabilir.
- Codex’in ortamından erişilebilen **PowerShell 7+** (`pwsh`). Windows PowerShell 5.1 (`powershell.exe`) yeterli değildir. PowerShell macOS/Linux için de vardır; bu sistemlerde gerçek Codex oturumu ile kabul testi yapılmadı.
- Git. Alternatif olarak GitHub’da **Code → Download ZIP** ile indirip arşivi açabilirsin.

```sh
git clone https://github.com/alicanselcuk/codex-tps-hook.git
cd codex-tps-hook
pwsh -NoLogo -NoProfile -File ./install.ps1 -Language tr
```

Kurucu iki çalışma dosyasını `<Codex ana dizini>/hooks/codex-tps-hook/` içine kopyalar ve `hooks.json` dosyasına bir `Stop` hook’u ekler. `CODEX_HOME` tanımlıysa onu, değilse kullanıcı profilinin `.codex` dizinini kullanır. Diğer hook’ları korur; mevcut kayıt ve önceki kurulum dosyalarını `backups/codex-tps-hook/` altında yedekler. Tekrar çalıştırmak aynı kaydı günceller.

**Yeni bir Codex oturumu aç.** Yönetilmeyen hook’lar incelenip güvenilir olarak işaretlenmelidir: Codex CLI’da **`/hooks`** kullan. Desktop’ta varsa hook inceleme ekranını, yoksa aynı Codex ana dizinini kullanan CLI’ı kullan. Kurucu güven kayıtlarını değiştirmez. Yeni/değişmiş tanım onaylanana kadar Codex hook’u atlayabilir. [Resmî hook belgesi](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).

Değişiklik yapmadan kurulumu görmek için:

```sh
pwsh -NoLogo -NoProfile -File ./install.ps1 -Language tr -DryRun
```

Farklı bir **aktif** Codex ana dizinine kurmak için `-CodexHome "/tam/yol/codex-ana-dizini"` ekle. Bu seçenek Codex’in hangi ayarı yüklediğini değiştirmez. Mevcut ayarlarda `[features].hooks = false` varsa hook’ları bilinçli olarak açmak gerekir; kurumsal politika kullanıcı hook’larını engelleyebilir. `config.toml` dosyasını komple değiştirme.

## Codex’e kurdurma

Yerel Codex sohbetine şu isteği gönderebilirsin:

> https://github.com/alicanselcuk/codex-tps-hook reposundaki hook’u kendi Codex’ime kur. README.tr.md ve AGENTS.md dosyalarını oku, scriptleri incele, aktif Codex ana dizinimi ve PowerShell sürümünü doğrula. Mevcut hook’larımı koruyarak kurucuyu çalıştır, repo testlerini yap ve kalan güven onayı adımını açıkla. Kişisel ayarlarımı veya oturum kayıtlarımı paylaşma. Gösterim dili Türkçe olsun.

Özelleştirme örneği:

> Codex TPS Hook yönergelerini oku. Kurulu hook’umu Türkçe gösterime geçir ve maliyet satırını gizle. Mevcut dosyaları yedekle, diğer hook’ları koru, metriklerin anlamını değiştirme ve sentetik veriyle doğrula. Yeni ayarın nasıl yüklenmesini sağlayacağımı anlat.

Codex kullanıcı isteğiyle kurulu dosyayı veya repo kopyasını düzenleyebilir. Yeniden kurulum paket scriptini ve fiyat kataloğunu kurulu dosyaların üzerine kopyalar; özel değişikliklerini önce repo kopyasına taşı. Önceki kurulum yedeklenir. Ayrıntılar [AGENTS.md](AGENTS.md) ve [özelleştirme belgesinde](docs/customization.md).

## Metriklerin anlamı

| Alan | Anlamı |
| --- | --- |
| Decode≈ | Output token / yaklaşık üretim süresi. İlk zamanlı reasoning/metin öğesinden üretim bitimine kadar hesaplanır. |
| TPS≈ | Output token / son kayıtlı model girdisinden üretim bitimine kadar süre. Girdi yoksa tur başlangıcı veya önceki kullanım kaydı sınırı kullanılır. Üretim öncesi beklemeyi içerir. |
| İlk üretim / İlk metin | Girdi sınırından ilk zamanlı üretim veya metin öğesine kadar gecikme. Kesin ilk-token ölçümü değildir. |
| Input / Output / Reasoning | Aynı son çağrının token sayıları. Reasoning, Output’a zaten dahildir; tekrar eklenmez. |
| Cache / Hit | Cache’ten okunan input ve bunun toplam input’a oranı. Input sıfırsa oran `n/a` olur. |
| Standard / Fast | Aynı çağrının iki API tarifesindeki tahmini token maliyeti. Gerçek fatura, abonelik harcaması veya kota tüketimi değildir. |

Hook yalnız seçilen `turn_id` içindeki son kullanım kaydını hesaplar, sonraki turda durur. Zaman bilgisi yoksa hız/gecikme alanları `n/a` olur; mevcut tokenlar yine gösterilir. Kullanım kaydı veya dosya yoksa, giriş bozuksa ya da olay `Stop` değilse sessizce başarılı çıkar. JSON `systemMessage` üretir; görevi engellemez veya devam ettirmez.

Fiyatlar [OpenAI API fiyatlandırmasından](https://developers.openai.com/api/docs/pricing) **13 Ekim 2026** tarihinde doğrulandı. Yalnız katalogdaki model kimlikleri kapsanır. Model/fiyat bilinmiyorsa veya gerekli cache-write verisi yoksa maliyet `n/a` olur. 272.000 input token üzeri uzun bağlam tarifesidir. İndirimler, bölgesel farklar, araç ücretleri ve abonelik koşulları hesaba katılmaz. Fiyatlar otomatik güncellenmez.

## Ayarlar, güncelleme ve kaldırma

Maliyet satırını gizlemek:

```sh
pwsh -NoLogo -NoProfile -File ./install.ps1 -Language tr -HideCost
```

İngilizce gösterim için `-Language en` kullan. Her kurulum çağrısı iki seçeneği de yeniden belirler; varsayılan dil İngilizce, maliyet satırı açıktır. Güncellerken tercih ettiğin seçenekleri tekrar geçir. Temiz repo kopyasını güncelleyip kurucuyu yeniden çalıştırabilirsin.

Kaldırmak:

```sh
pwsh -NoLogo -NoProfile -File ./install.ps1 -Action Uninstall
```

Yalnız bu paketin seçilen `hooks.json` içindeki kaydı kaldırılır. Kurulu dosyalar ve yedekler korunur. Diğer ayar katmanlarındaki eski metrik hook’ları ayrıca çalışabilir. Değişiklikten sonra yeni oturum aç; Codex isterse değişen hook tanımını yeniden incele.

## Doğrulama ve sorun çözme

```sh
pwsh -NoLogo -NoProfile -File ./turn-metrics.tests.ps1
pwsh -NoLogo -NoProfile -File ./install.tests.ps1
```

Testler geçici sentetik kayıtlar ve izole ayar dizinleri kullanır; gerçek sohbetleri değiştirmez. Hesaplar, eksik veri, Türkçe karakterler, seçenekler, kurulum birleştirmesi, yedekler, tekrar kurma/kaldırma, bozuk ayarlar ve komut yolları kontrol edilir. Gerçek Codex arayüzü kabulünü ve güven onayını test etmez.

Hiç çıktı yoksa `pwsh --version`, aktif Codex ana dizini, hook güven onayı, hook kapatma ayarı/politikası ve oturumdaki `token_usage_record` kayıtlarını kontrol et. Çıktı iki kez görünüyorsa `/hooks` içinde eski/global/proje hook’larını ve `config.toml` içindeki `[hooks]` tanımlarını incele; yalnız doğruladığın kopyayı kaldır.

Her `Stop` olayında oturum dosyası yerelde taranır. Çok büyük kayıtlar **5 saniyelik hook süresini** aşabilir. Hook ağ isteği yapmaz, veri yüklemez, veritabanına yazmaz, API anahtarı istemez ve model/efor/tier ayarını değiştirmez. Kurucu yalnız yerel ayar/dosya/yedek yazar. Gerçek oturum kayıtlarını veya hesap ayarlarını repoya ekleme.

Bu topluluk projesi resmî OpenAI ürünü değildir. [MIT lisansı](LICENSE) ile paylaşılır.
