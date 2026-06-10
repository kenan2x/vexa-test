"""Unit tests for Turkish-aware text normalization in metrics.py.

These run without a GPU or the transcription service — pure string logic.

    python -m tests.quality.test_metrics_tr      # standalone
    pytest tests/quality/test_metrics_tr.py      # via pytest
"""
from __future__ import annotations

from .metrics import normalize_text, wer, cer


def test_dotted_capital_I_has_no_combining_dot():
    # "İ".lower() in plain Python leaves a U+0307 combining dot above, which
    # silently breaks equality with a plain "i". Normalization must remove it.
    out = normalize_text("İYİ", lang="tr")
    assert out == "iyi", repr(out)
    assert "̇" not in out


def test_dotless_capital_I_maps_to_dotless_lower():
    # Turkish: "I".lower() should be "ı" (dotless), not "i".
    assert normalize_text("IŞIK", lang="tr") == "ışık"


def test_turkish_specific_letters_lowercase():
    assert normalize_text("ÇĞÖŞÜ", lang="tr") == "çğöşü"


def test_casing_does_not_inflate_wer():
    # A correctly-cased hypothesis vs an upper-case reference must score 0 WER.
    ref = "İstanbul Işık ve Çağ"
    hyp = "istanbul ışık ve çağ"
    assert wer(ref, hyp, lang="tr") == 0.0
    assert cer(ref, hyp, lang="tr") == 0.0


def test_combining_dot_stripped_even_without_tr_flag():
    # Even on the generic path, a stray combining dot from str.lower("İ")
    # should not survive and cause a spurious mismatch.
    assert normalize_text("İYİ") == normalize_text("iyi")


def test_old_behavior_would_have_failed():
    # Documents the bug we fixed: raw str.lower keeps the combining dot, so the
    # naive comparison would NOT be equal. Our normalize_text makes it equal.
    naive_ref = "İYİ".lower()          # 'i̇yi̇'
    assert "̇" in naive_ref        # the bug is real
    assert normalize_text("İYİ", lang="tr") == "iyi"  # fixed


def _run():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\n{len(fns)} passed")


if __name__ == "__main__":
    _run()
