"""Phase 7 — optional LLM post-correction for finalized transcript segments.

Adds punctuation + terminology fixes via an *injected* LLM call (e.g. a LiteLLM
gateway). A guardrail rejects over-correction: if the corrected text changes more
than ``max_change_ratio`` of the words, the original is kept — the model is meant
to punctuate / fix terminology, NOT rewrite meaning ("aşırı müdahale alarmı").

Design notes
------------
* Dependency-light and side-effect free → unit-testable, safe to import anywhere.
* The real LLM client is injected via ``llm_call``; nothing is called automatically.
  Wiring this into the collector's segment pipeline + pointing ``llm_call`` at the
  LiteLLM gateway is the remaining (network-gated) integration step.
* Punctuation- and case-only edits are FREE (that is exactly what we want the model
  to do); only genuine word substitutions/insertions/deletions count toward the
  over-correction ratio.
"""
from __future__ import annotations

import re
from typing import Callable, Dict, List, Optional

# An LLM call takes chat messages and returns the assistant's text.
LLMCall = Callable[[List[Dict[str, str]]], str]

DEFAULT_MAX_CHANGE_RATIO = 0.4

_SYSTEM_PROMPT = (
    "Sen bir transkript düzeltme aracısın. Görevin SADECE noktalama işaretlerini "
    "düzeltmek ve verilen terim sözlüğüne göre yanlış yazılmış terimleri düzeltmektir. "
    "Cümlenin anlamını DEĞİŞTİRME, kelime ekleme veya çıkarma yapma, yeniden yazma. "
    "Yalnızca düzeltilmiş metni döndür."
)

_WORD_RE = re.compile(r"\w+", flags=re.UNICODE)


def build_correction_request(text: str, glossary: Optional[str] = None) -> List[Dict[str, str]]:
    """Build the chat messages for a guarded punctuation/terminology correction."""
    system = _SYSTEM_PROMPT
    if glossary and glossary.strip():
        system += f"\n\nTerim sözlüğü: {glossary.strip()}"
    return [
        {"role": "system", "content": system},
        {"role": "user", "content": text},
    ]


def _tokenize(s: str) -> List[str]:
    # Lowercase + word-chars only, so punctuation/casing changes are not counted.
    return _WORD_RE.findall(s.lower())


def _word_edit_distance(a: List[str], b: List[str]) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, tok_a in enumerate(a, start=1):
        cur = [i]
        for j, tok_b in enumerate(b, start=1):
            cost = 0 if tok_a == tok_b else 1
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost))
        prev = cur
    return prev[-1]


def word_change_ratio(original: str, corrected: str) -> float:
    """Fraction of words changed (ignores punctuation/case). 0.0 = identical words."""
    a = _tokenize(original)
    b = _tokenize(corrected)
    if not a:
        return 0.0 if not b else 1.0
    return _word_edit_distance(a, b) / max(1, len(a))


def correct_segment(
    text: str,
    glossary: Optional[str] = None,
    llm_call: Optional[LLMCall] = None,
    max_change_ratio: float = DEFAULT_MAX_CHANGE_RATIO,
) -> str:
    """Return a corrected segment, or the original if correction is unsafe/disabled.

    Safe by construction: with ``llm_call=None`` (the default) the input is returned
    unchanged, so enabling post-correction is an explicit opt-in.
    """
    text = (text or "").strip()
    if not text or llm_call is None:
        return text

    messages = build_correction_request(text, glossary)
    try:
        corrected = (llm_call(messages) or "").strip()
    except Exception:
        # Correction must never break the transcription pipeline.
        return text

    if not corrected:
        return text

    if word_change_ratio(text, corrected) > max_change_ratio:
        # Over-correction alarm: the model rewrote too much — keep the original.
        return text

    return corrected
