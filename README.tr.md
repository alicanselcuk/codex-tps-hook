# Codex TPS Hook

Codex için **istek toplamı, sohbet toplamı ve ayrı ana/alt ajan hızları** gösteren yerel hook.

[English](README.md) · [Güncelleme notları](CHANGELOG.md) · [Codex yönergeleri](AGENTS.md) · [Özelleştirme](docs/customization.md) · [MIT](LICENSE)

Artık yalnız son API çağrısı gösterilmez. Bu istekteki ana oturum ve alt ajanlar ayrı hesaplanır; genel toplamda input, output, reasoning, cache, hit oranı ve tahmini API maliyeti bulunur. Altındaki **Sohbetin tamamı** bölümü geçmiş istekleri ve onların alt ajanlarını da kapsar.

## Kurulum / güncelleme

Gerekenler:

- Komut hook'larını ve JSONL `token_usage_record` kayıtlarını destekleyen yerel Codex CLI/Desktop.
- **PowerShell 7+** (`pwsh`). Windows PowerShell 5.1 yeterli değildir.
- **Python 3.10+**: SQLite arşivi ve alt ajan keşfi için bu sürümle birlikte gereklidir. Ek pip paketi, API anahtarı veya ağ servisi gerekmez.
- Git veya GitHub'dan indirilen ZIP.

Windows üzerinde Codex CLI 0.163.0, PowerShell 7.6.6 ve Python 3.14.0 ile doğrulandı. macOS/Linux'ta gerçek Codex oturumu kabul testi yapılmadı.

```sh
git clone https://github.com/alicanselcuk/codex-tps-hook.git
cd codex-tps-hook
pwsh -NoLogo -NoProfile -File ./install.ps1 -Language tr
```

Eski, temiz repo kopyasını güncelledikten sonra kurucuyu yeniden çalıştır. Tercih ettiğin seçenekleri tekrar geçir:

```sh
pwsh -NoLogo -NoProfile -File ./install.ps1 -Language tr -HideCost
pwsh -NoLogo -NoProfile -File ./install.ps1 -PythonPath "/python/tam/yolu" -DryRun
```

Kurucu `python` veya `python3` komutunu bulur; özel yol için `-PythonPath` kullanılır. Bütün yardımcı dosyalar `<Codex ana dizini>/hooks/codex-tps-hook/` altına kurulur. Makineye özel yollar kurulum sırasında üretilir. **Stop 30 saniye**, **SubagentStop 5 saniye** süre bütçesiyle kaydedilir. Diğer hook'lar korunur; tekrar kurulum kayıtları çoğaltmaz, mevcut kullanım veritabanını ve özel veritabanı ayarını korur. Eski dosya ve ayarlar `backups/codex-tps-hook/` altına yedeklenir.

Aktif ana dizin `CODEX_HOME`, yoksa profilin `.codex` dizinidir. `-CodexHome` yalnız kurulum hedefini seçer; Codex'in yüklediği ayarı değiştirmez. Kurucu `config.toml`, model/efor/tier ve güven kayıtlarını değiştirmez.

**Yeni bir Codex oturumu açıp CLI'da `/hooks` üzerinden iki hook'u da onayla.** Desktop'ta varsa hook inceleme ekranını, yoksa aynı ana dizini kullanan CLI'ı kullan. Değişmiş tanımlar yeniden inceleme gerektirir: [Codex güven kuralı](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).

## Hesaplar

- **Bu istek:** aynı kök isteğe bağlı bütün API çağrıları. Ana oturum ve alt ajanlar ayrı gösterilir.
- **Sohbetin tamamı:** bu sohbetin geçmiş çağrıları ve o isteklere bağlı alt ajanlar. Başka sohbetler ve devralınan parent çağrıları dahil edilmez.
- **TPS / Decode:** ölçülebilen aynı çağrıların toplam output / toplam süre hesabıdır. Paralel ajan hızları toplanmaz. TPS üretim öncesi beklemeyi içerir; Decode yaklaşık üretim süresidir. Araç çalıştırması üretim sayılmaz.
- **Gecikme:** mevcut ilk üretim/metin öğesi gecikmelerinin ortalamasıdır; kesin ilk-token ölçümü değildir.
- **Token:** input/output/reasoning toplanır. Reasoning zaten output'un içindedir, ikinci kez eklenmez.
- **Cache / Hit:** cache okumaları toplanır. Oran, eşleşen toplam cache / toplam input'tur; grup yüzdelerinin ortalaması değildir.
- **Maliyet:** her çağrı kendi modeli ve bağlam tarifesiyle hesaplanıp toplanır. Standard/Fast tahmini API karşılığıdır; abonelik faturası, gerçek hız katmanı veya kredi tüketimi değildir.

Eksik zaman ölçümlerinde kapsam gösterilir. Kısmi token/maliyet toplamında `+ ?`, tamamen bilinmeyen değerde `n/a` görünür. `-HideCost` bütün maliyet satırlarını ve sohbet satırlarındaki maliyeti gizler; hesaplamayı/arşivi kapatmaz. Kurucu varsayılanları İngilizce ve açık maliyettir; doğrudan script varsayılanı Türkçedir.

## Yerel arşiv ve sınırlar

Varsayılan arşiv `<kurulu hook>/usage/data/usage.sqlite3` dosyasıdır. Kimlikler, proje yolları, model adları ve sayısal ölçümler tutulur; **prompt ve yanıt metni saklanmaz**. Hiçbir veri yüklenmez. Aynı çağrı tekrar sayılmaz; önceki ölçüm ve fiyatlar korunur.

Ana Stop mevcut sohbet ve alt ajan dosyalarını okur. Alt ajanları bulmak için Codex'in `state_5.sqlite` indeksi **salt okunur** açılır. SubagentStop ayrıca ajan bittiğinde kayıt yapar. Ekran kapanış anının fotoğrafıdır: sürmekte olan ajanın sonraki çağrıları daha sonra arşive girer, önceki kart değişmez.

Eski dosya kaybolmuşsa, indeks okunamıyorsa veya arşiv yazımı başarısızsa kısmi kapsam uyarısı çıkar. Kesilip daha sonra hook çalışmayan iş eksik kalabilir. Çok büyük geçmiş 30 saniyeyi de aşabilir; Codex kayıt/indeks biçimi değişirse uyarlama gerekebilir.

## Codex'e kurdurma

> https://github.com/alicanselcuk/codex-tps-hook reposundaki hook'u kur. README.tr.md ve AGENTS.md dosyalarını oku; kurucuyu ve çalışma dosyalarını incele. Aktif Codex ana dizinimi ve PowerShell/Python sürümlerini doğrula, mevcut hook'larımı koru. Repo testlerini çalıştır, kalan güven onayını açıkla. Dil Türkçe olsun. Kişisel ayarlarımı, veritabanımı veya oturum kayıtlarımı paylaşma.

Özel düzenlemeler için [özelleştirme belgesine](docs/customization.md) bak. Yeniden kurulum paket kodunu kopyalar; özel kodunu korumak için repo kopyasına taşı.

## Doğrulama / kaldırma

```sh
pwsh -NoLogo -NoProfile -File ./turn-metrics.tests.ps1
pwsh -NoLogo -NoProfile -File ./install.tests.ps1
python -m unittest discover -s tests -v
pwsh -NoLogo -NoProfile -File ./install.ps1 -Action Uninstall
```

Testler sentetik kayıt, geçici veritabanı ve izole kurulum kullanır. Gerçek Codex arayüzü ve güven onayı ayrıca doğrulanır. Kaldırma yalnız paketin iki hook kaydını siler; dosyalar, kullanım arşivi ve yedekler kalır.

Çift çıktı varsa `/hooks` içindeki eski/proje/inline kayıtları incele; yalnız doğruladığın kopyayı kaldır. Hiç çıktı yoksa aktif ana dizini, güveni, Python/PowerShell erişimini ve `token_usage_record` desteğini kontrol et.

Fiyat kataloğu 13 Ekim 2026 tarihli [resmî API fiyatlandırması](https://developers.openai.com/api/docs/pricing) snapshot'ıdır ve bu güncellemede değiştirilmemiştir. Gerçek kayıtları, veritabanını, üretilen ayarları veya güven durumunu repoya ekleme.

Resmî OpenAI ürünü değildir.
