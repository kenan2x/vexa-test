"""Phase 7 — tests for LLM post-correction guardrails (no real LLM, no GPU).

    pytest tests/collector/test_tr_postcorrect.py -v
"""
from meeting_api.collector.tr_postcorrect import (
    build_correction_request,
    word_change_ratio,
    correct_segment,
    DEFAULT_MAX_CHANGE_RATIO,
)


def test_request_has_meaning_preserving_guard():
    msgs = build_correction_request("rapor geldi", glossary="valör, takas")
    assert msgs[0]["role"] == "system"
    assert "anlamını DEĞİŞTİRME" in msgs[0]["content"].replace("̇", "")
    assert "valör, takas" in msgs[0]["content"]
    assert msgs[1] == {"role": "user", "content": "rapor geldi"}


def test_punctuation_and_case_changes_are_free():
    # Adding punctuation / capitalization (same letters) must not count as changes.
    assert word_change_ratio("rapor geldi teşekkurler", "Rapor geldi, teşekkurler!") == 0.0


def test_letter_level_spelling_fix_counts_as_change():
    # A diacritic/spelling fix (teşekkurler → teşekkürler) IS a real word change,
    # so it is correctly counted toward the over-correction ratio.
    assert word_change_ratio("teşekkurler", "teşekkürler") == 1.0


def test_word_substitution_counts():
    # One of four words replaced → 0.25.
    assert word_change_ratio("bir iki uc dort", "bir iki BES dort") == 0.25


def test_accepts_punctuation_only_correction():
    # Model only adds punctuation → accepted.
    llm = lambda _msgs: "Rapor geldi, teşekkürler."
    out = correct_segment("rapor geldi teşekkürler", llm_call=llm)
    assert out == "Rapor geldi, teşekkürler."


def test_rejects_over_correction():
    # Model rewrites the whole thing → over-correction alarm → keep original.
    original = "bir iki uc dort bes"
    llm = lambda _msgs: "tamamen farklı bir cümle yazdım burada"
    assert correct_segment(original, llm_call=llm) == original


def test_disabled_by_default():
    # No llm_call → input returned unchanged (opt-in by construction).
    assert correct_segment("rapor geldi") == "rapor geldi"


def test_llm_failure_falls_back_to_original():
    def boom(_msgs):
        raise RuntimeError("gateway timeout")
    assert correct_segment("rapor geldi", llm_call=boom) == "rapor geldi"


def test_empty_llm_output_falls_back():
    assert correct_segment("rapor geldi", llm_call=lambda _m: "") == "rapor geldi"


def test_threshold_is_configurable():
    original = "bir iki uc dort"
    # 2 of 4 words changed = 0.5 ratio.
    llm = lambda _m: "bir iki YEDI SEKIZ"
    assert correct_segment(original, llm_call=llm, max_change_ratio=0.6) == "bir iki YEDI SEKIZ"
    assert correct_segment(original, llm_call=llm, max_change_ratio=0.4) == original
    assert DEFAULT_MAX_CHANGE_RATIO == 0.4
