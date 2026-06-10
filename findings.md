# Türkçe STT İyileştirme — findings

Brief: Vexa Türkçe transkripsiyon kalitesini ölçülebilir şekilde yükseltmek.
Her faz, Faz 1 harness'ında sayısal kanıt olmadan "tamamlandı" sayılmaz.

## ⚠️ Çalışma ortamı kısıtları (önce oku)

Bu işin yapıldığı Claude Code konteyneri **GPU'suz ve dış-ağ kısıtlı**:

| Kaynak | Durum | Etki |
|---|---|---|
| GPU | **yok** (`nvidia-smi` → none) | faster-whisper modeli koşturulamaz |
| `faster_whisper`, `gtts` | kurulu değil | TTS üretimi + gerçek transkripsiyon burada koşmaz |
| Upstream git (Vexa-ai/vexa) | proxy yalnızca `kenan2x/vexa-test`'e izin veriyor | fork sync bu konteynerden yapılamaz |
| Dış endpoint'ler (Chatterbox, LiteLLM gw, paipsap01 H200) | erişilemez | Faz 7 / TTS alternatifi burada koşmaz |

**Sonuç:** Kod değişiklikleri ve **GPU gerektirmeyen birim testleri** burada yapıldı ve
koşuldu. Gerçek **WER ölçümleri GPU host'ta (paipsap01)** koşulmalı — her faz için
tam komutlar aşağıda. Bu dosya, neyin burada doğrulandığını / neyin GPU host'a kaldığını
net ayırır.

---

## Faz 1 — Türkçe ölçüm altyapısı  ✅ (kod + birim test burada koşuldu)

### Yapılanlar
1. **`phrases.py`** — `LANGUAGES`'a `tr` eklendi; `PHRASES["tr"]` 9 cümle (genel + finans
   terimleri: valör, takas, teminat, saklama; yazıyla sayı "bin iki yüz elli"; tarih/saat
   "on beş Mart saat on dörtte"). `PHRASES_BY_DOMAIN["tr"]` = general + finance.
2. **`metrics.py`** — `normalize_text` artık Türkçe-doğru küçük harf yapıyor:
   - `"İ" → "i"` (Python `.lower()` "İ" için `i` + U+0307 combining-dot üretiyordu →
     sessizce WER bozuyordu). Combining-dot her dilde stripleniyor.
   - `"I" → "ı"` (dotless), `Ş/Ğ/Ç/Ö/Ü` doğru.
   - `wer()` / `cer()` / `normalize_text()` geriye-uyumlu opsiyonel `lang` parametresi aldı;
     `run_quality.py` case dilini geçiriyor.
3. **`test_metrics_tr.py`** — 6 birim test, hem standalone hem pytest.

### Burada koşulan kanıt
```
$ python -m tests.quality.test_metrics_tr     →  6 passed
$ pytest tests/quality/test_metrics_tr.py -q  →  6 passed in 0.02s
```
Eski davranışın bug'ı testle belgelendi (`"İYİ".lower()` combining-dot içeriyor →
naive karşılaştırma eşit değil; `normalize_text` ile eşit).

### GPU host'ta koşulacak (baseline WER) — bu konteynerde yapılamaz
```bash
cd services/transcription-service
python -m tests.quality.dataset_generate --languages tr --domains general finance
python -m tests.quality.run_quality      --languages tr --domains general finance
# → çıkan baseline WER/CER buraya tabloya işlenecek
```
> Baseline WER: **<GPU host'ta doldur>**

---

## Faz 3 — `language=tr` plumbing  ✅ (zaten döşeli; guard test burada koşuldu)

**Bulgu:** Brief'in "üretim yolu `language` göndermiyor" teşhisi **bu güncel sürümde
geçerli değil**. Akış zaten tam:

```
index.ts:2156   currentLanguage = botConfig.language
index.ts:1348   explicitLang = currentLanguage (≠ 'auto')
index.ts:1355   transcriptionClient.transcribe(audio, lang, contextPrompt)
transcription-client.ts:140   → form field  name="language"  → transcription-service
```

Yani `botConfig.language = "tr"` set edilince `tr` servise multipart form field olarak
ulaşıyor. **Kod değişikliği gerekmedi.** Regresyona karşı bir guard testi eklendi:

`transcription-client.language.test.ts` (fetch mock, GPU'suz koşar):
```
$ node -e "require('tsx/cjs');require('.../transcription-client.language.test.ts')"
  ✓ language form field is present
  ✓ language value is "tr"
  ✓ prompt (context bias) form field is present
  ✓ prompt value is forwarded with correct UTF-8 (Turkish chars intact)
  ✓ verbose_json requested
  All assertions passed
```

> **Nasıl açılır:** bot config'inde `language: "tr"` (veya `allowed_languages: ["tr"]`).
> Otomatik-tespit vs sabit `tr` WER karşılaştırması GPU host'ta `run_quality` ile yapılmalı.

---

## Faz 4 — confirmation mantığı (TR hipotez doğrulaması)  ✅ test burada koşuldu / ⏸ fix ertelendi

Brief kuralı: *"Faz 4 hipotezi doğrulanmadan speaker-streams'e davranış değişikliği merge
etme."* Gerçek-ses pipeline'ı bu konteynerde (GPU'suz) koşulamadığından **davranış
değişikliği merge edilmedi**; bunun yerine mevcut davranış birim testle belgelendi.

`speaker-streams.tr-confirm.test.ts` (tsx/CJS, GPU'suz koşar — hepsi geçti):

| Senaryo | Davranış | Sonuç |
|---|---|---|
| **A** full-text fallback (tek segment, duraklama → tekrar) | tüm metni, **trailing kelime dahil** onaylar | ⚠️ TR riski (onaylandı→onaylandığında erken commit) |
| **B** word-prefix (çok segment) | yalnız kararlı prefix'i emit eder, **trailing kelimeyi tutar** | ✅ doğru |
| **C** hallucination filtresi | **tek Türkçe kelimeleri** (rapor, geldi, proje, bütçe...) eler; çok-kelimeli ifadeleri geçirir | ⚠️ yeni bulgu |

### Teşhis (kanıtlı)
1. **Risk full-text fallback yolunda** (`speaker-streams.ts:262-275`): Whisper tek bir
   çok-kelimeli segment döndürüp metin 2 geçiş sabit kalınca tüm cümle (son kelime dahil)
   onaylanıyor. Word-prefix yolu (`:200-260`) `prefixLen < currentWords.length` sayesinde
   son kelimeyi zaten tutuyor — yani sorun yalnız fallback'te.
2. **Yan bulgu:** Hallucination filtresi tek kelimeleri eliyor. Word-prefix yolu segment
   başına tek kelime emit ettiğinden, Whisper kelime-başına-segment döndürdüğünde gerçek
   içerik sessizce kayboluyor. Türkçe'de tek-kelime cümleler anlamlı olduğundan bu önemli.

### Neden fix ertelendi
"Trailing word hold"un *doğru* yapılması, tutulan kelimenin **audio offset'inin** ileri
sarılmamasını gerektirir; bu da kelime-seviyesi zaman damgası ister. Full-text fallback
yolunda kelime zamanlaması yok → tutulan kelimenin sesi ya kaybolur ya çift sayılır.
Doğru çözüm yapısal (onayı tamamen word-level'a taşımak) ve **gerçek Whisper çıktısı +
GPU ile doğrulanmadan** merge edilmemeli (brief kuralı). Test regresyon tabanı olarak kaldı.

### GPU host'ta yapılacak (fix doğrulaması)
- Gerçek TR sesle A senaryosunun pratikte ne sıklıkta tetiklendiğini ölç.
- Aday fix'leri (full-text fallback'i word-level'a taşı / `confirmThreshold` sweep) Faz 1
  harness'ında WER ile karşılaştır; iyileşme kanıtlanırsa flag'i aç.

---
<!-- Faz 2, 5, 6, 7: GPU/dış-endpoint gerektiriyor — aşağıda plan + komutlar -->

## Faz 2 / 5 / 6 / 7 — GPU + dış endpoint gerektiren fazlar (bu konteynerde koşulamaz)

Bunlar kod-üstü değişiklik + canlı ölçüm gerektiriyor; **GPU host'ta (paipsap01)**
yapılmalı. Tasarım + komutlar:

- **Faz 2 (Config A/B):** `COMPUTE_TYPE=float16` vs `int8`, `MODEL_SIZE=large-v3` vs
  `-turbo`. Sadece env + `run_quality --languages tr` ile ölçüm; her kombinasyonu tabloya.
- **Faz 5 (Eşik kalibrasyonu):** `LOG_PROB_THRESHOLD`/`NO_SPEECH_THRESHOLD`/
  `COMPRESSION_RATIO_THRESHOLD` grid sweep (env + servis restart), hedef: yanlış elenen TR
  segment ↓. (Faz 4'teki tek-kelime filtre bulgusu da burada incelenmeli.)
- **Faz 6 (Context biasing):** Bot API `context` alanı → `prompt` başına kurum sözlüğü
  prepend (mevcut `lastConfirmedText` önüne; 224 token'a kırp). Terim isabet metriği.
- **Faz 7 (LLM post-correction):** finalize segmentlere LiteLLM hook (llmgw...takasbank),
  "anlamı değiştirme" guard'lı. WER ↓ + değişen-kelime-oranı sınırı.
