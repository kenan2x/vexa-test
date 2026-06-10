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
<!-- sonraki fazlar buraya eklenecek -->
