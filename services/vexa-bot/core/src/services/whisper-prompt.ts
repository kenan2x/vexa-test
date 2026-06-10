/**
 * Phase 6 — context biasing for Whisper.
 *
 * Builds the `prompt` (initial_prompt) sent to transcription-service by prepending
 * a domain glossary / org terminology before the rolling confirmed-text context.
 * Whisper's prompt window is ~224 tokens; we clip conservatively by words, always
 * keeping the glossary (the bias) and the MOST RECENT confirmed words for continuity.
 *
 * An empty glossary returns the confirmed context unchanged — no behavior change.
 */

/** Whisper's documented prompt limit is 224 tokens. We approximate tokens by
 *  whitespace words (BPE usually ≥1 token/word, so this is a safe under-estimate). */
export const WHISPER_PROMPT_MAX_TOKENS = 224;

export function buildWhisperPrompt(
  glossary: string | undefined | null,
  lastConfirmed: string | undefined | null,
  maxTokens: number = WHISPER_PROMPT_MAX_TOKENS,
): string {
  const gloss = (glossary ?? '').trim();
  const last = (lastConfirmed ?? '').trim();

  if (!gloss) return last;                 // no context configured → unchanged
  if (!last) return clipWords(gloss, maxTokens);

  const glossWords = gloss.split(/\s+/);
  if (glossWords.length >= maxTokens) {
    // Glossary alone fills (or overflows) the budget — keep its head.
    return glossWords.slice(0, maxTokens).join(' ');
  }

  const remaining = maxTokens - glossWords.length;
  // Keep the tail (most recent) of the rolling context for continuity.
  const lastWords = last.split(/\s+/).slice(-remaining);
  return [...glossWords, ...lastWords].join(' ');
}

function clipWords(text: string, maxTokens: number): string {
  const words = text.split(/\s+/);
  return words.length <= maxTokens ? text : words.slice(0, maxTokens).join(' ');
}
