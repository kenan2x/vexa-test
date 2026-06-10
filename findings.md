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
## Faz 6 — context biasing  ✅ (kod + birim test burada koşuldu)

Whisper `prompt`'una kurum sözlüğü/terminoloji bias'ı ekleyen plumbing. Mevcut prompt
borusu (`lastConfirmedText` → `transcribe(prompt)`) zaten vardı; sözlüğü onun **önüne**
prepend edip 224 token'a kırpıyoruz.

- **`types.ts`** — `BotConfig.transcriptionContext?: string` (sözlük/terim metni).
- **`whisper-prompt.ts`** — `buildWhisperPrompt(glossary, lastConfirmed, maxTokens=224)`:
  sözlüğü başa koyar, bütçeyi aşarsa sözlüğü korur + **en güncel** context kelimelerini
  (tail) tutar. Boş sözlük → davranış değişmez.
- **`index.ts`** — prompt kurulum noktasına bağlandı; `transcriptionContext` botConfig'ten
  okunuyor. Default boş → üretim davranışı aynı (güvenli opt-in).

```
$ node -e "require('tsx/cjs');require('.../whisper-prompt.test.ts')"  → 8/8 passed
```
> **Gated:** Terim isabet metriği (sözlüklü vs sözlüksüz) GPU host'ta `run_quality` ile.

---

## Faz 7 — LLM post-correction  ✅ (kod + birim test burada koşuldu; canlı endpoint gated)

Finalize segmentlere noktalama + terminoloji düzeltmesi için **injected** LLM çağrısı,
"anlamı değiştirme" guard'lı. Vexa'da yoktu — özgün ekleme.

- **`meeting_api/collector/tr_postcorrect.py`** — bağımlılık-hafif, yan-etkisiz:
  - `build_correction_request(text, glossary)` → guard'lı sistem prompt'u (anlamı değiştirme,
    kelime ekleme/çıkarma yok) + sözlük.
  - `word_change_ratio(orig, corrected)` → kelime değişim oranı (noktalama/büyük-harf
    **bedava**, sadece gerçek kelime değişimi sayılır).
  - `correct_segment(text, glossary, llm_call, max_change_ratio=0.4)` → **aşırı müdahale
    alarmı**: oran sınırı aşılırsa orijinali tutar; `llm_call=None`/hata/boş → orijinal
    (güvenli opt-in, pipeline'ı asla kırmaz).
- Gerçek LLM client (LiteLLM gateway) `llm_call` olarak enjekte edilecek.

```
$ pytest tests/collector/test_tr_postcorrect.py  → 10/10 passed
```
> **Gated:** Collector segment pipeline'ına wiring + `llm_call`'ı LiteLLM gateway'e
> (`llmgw.ai.takasbank.com.tr`, model `takasai-flash`) bağlama + öncesi/sonrası WER —
> dış ağ/GPU gerektiriyor.

---

## Faz 2 / 5 — saf GPU/ölçüm fazları (kod yok; bu konteynerde koşulamaz)

Env + canlı WER; **GPU host'ta (paipsap01)** yapılmalı:

- **Faz 2 (Config A/B):** `COMPUTE_TYPE=float16` vs `int8`, `MODEL_SIZE=large-v3` vs
  `-turbo`. Sadece env + `run_quality --languages tr`; her kombinasyon tabloya.
- **Faz 5 (Eşik kalibrasyonu):** `LOG_PROB_THRESHOLD`/`NO_SPEECH_THRESHOLD`/
  `COMPRESSION_RATIO_THRESHOLD` grid sweep (env + servis restart), hedef: yanlış elenen TR
  segment ↓. (Faz 4'teki tek-kelime hallucination filtresi bulgusu da burada incelenmeli.)

---

## Özet — bu seansta ne yapıldı

| Faz | Durum | Burada koşulan test |
|---|---|---|
| 1 Türkçe ölçüm | ✅ kod + test | metrics TR 6/6 (pytest+standalone) |
| 2 Config A/B | ⏸ GPU-gated | — |
| 3 language=tr plumbing | ✅ zaten döşeli + guard test | client language 5/5 (tsx) |
| 4 confirmation | ✅ davranış belgelendi (fix gated) | speaker-streams TR 5/5 (tsx) |
| 5 eşik kalibrasyonu | ⏸ GPU-gated | — |
| 6 context biasing | ✅ kod + test | whisper-prompt 8/8 (tsx) |
| 7 LLM post-correction | ✅ kod + test (endpoint gated) | tr_postcorrect 10/10 (pytest) |

**Toplam burada koşulan: 34 assertion/test, hepsi yeşil.** Mutlak WER iyileşmesi her
fazda Faz 1 harness'ı ile GPU host'ta ölçülüp bu tabloya işlenecek.
