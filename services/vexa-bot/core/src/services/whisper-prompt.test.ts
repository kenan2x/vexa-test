/**
 * Phase 6 — tests for buildWhisperPrompt (context biasing). GPU-free, pure logic.
 * Run: node -e "require('tsx/cjs');require('./src/services/whisper-prompt.test.ts')"
 */
import { buildWhisperPrompt, WHISPER_PROMPT_MAX_TOKENS } from './whisper-prompt';

let failures = 0;
function assert(cond: boolean, msg: string) {
  if (!cond) { console.error(`  ✗ ${msg}`); failures++; }
  else { console.log(`  ✓ ${msg}`); }
}

console.log('Phase 6 — buildWhisperPrompt');

// 1. No glossary → unchanged (no behavior change in production by default)
assert(buildWhisperPrompt('', 'son onaylanan metin') === 'son onaylanan metin',
  'empty glossary returns confirmed context unchanged');
assert(buildWhisperPrompt(undefined, undefined) === '',
  'all empty → empty string');

// 2. Glossary prepended before rolling context
assert(buildWhisperPrompt('valör takas teminat saklama', 'rapor hazır') ===
  'valör takas teminat saklama rapor hazır',
  'glossary is prepended before confirmed context');

// 3. Glossary only (no context)
assert(buildWhisperPrompt('valör teminat', '') === 'valör teminat',
  'glossary alone is returned when no context');

// 4. Clip to token budget, keeping glossary + MOST RECENT context words
const gloss = 'valör teminat';                 // 2 words
const longCtx = Array.from({ length: 20 }, (_, i) => `w${i}`).join(' ');
const out = buildWhisperPrompt(gloss, longCtx, 5);
assert(out.split(/\s+/).length === 5, 'clipped to maxTokens (5)');
assert(out.startsWith('valör teminat '), 'glossary preserved at head after clip');
assert(out.endsWith('w17 w18 w19'), 'most recent context words kept (tail)');

// 5. Oversized glossary is itself clipped
const bigGloss = Array.from({ length: 300 }, (_, i) => `g${i}`).join(' ');
const out2 = buildWhisperPrompt(bigGloss, 'ctx');
assert(out2.split(/\s+/).length === WHISPER_PROMPT_MAX_TOKENS,
  'oversized glossary clipped to 224-token limit');

console.log(failures === 0 ? '\nAll assertions passed' : `\n${failures} assertion(s) failed`);
process.exit(failures === 0 ? 0 : 1);
