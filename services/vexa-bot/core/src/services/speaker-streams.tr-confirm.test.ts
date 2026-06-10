/**
 * Phase 4 — documents the confirmation behavior of SpeakerStreamManager for
 * agglutinative (Turkish) input, where a word can gain a suffix between passes
 * ("onaylandı" → "onaylandığında"). Asserts CURRENT behavior (no production
 * change) to establish a regression baseline before any trailing-word-hold fix.
 *
 * Run (CommonJS register, project compiles to CJS):
 *   node -e "require('tsx/cjs');require('./src/services/speaker-streams.tr-confirm.test.ts')"
 */
import { SpeakerStreamManager } from './speaker-streams';
import { isHallucination } from './hallucination-filter';

interface Seg { text: string; start: number; end: number; }

let failures = 0;
function assert(cond: boolean, msg: string) {
  if (!cond) { console.error(`  ✗ ${msg}`); failures++; }
  else { console.log(`  ✓ ${msg}`); }
}

function newManager(confirmed: string[]) {
  const m = new SpeakerStreamManager({ confirmThreshold: 2 });
  m.onSegmentConfirmed = (_sid, _name, transcript) => { confirmed.push(transcript); };
  return m;
}

// ── Case A: single multi-word Whisper segment + a pause (repeat) ──────────────
// The full-text fallback path confirms the WHOLE text — including the trailing
// word — once it is stable for confirmThreshold passes. In Turkish this is the
// risk: if "onaylandı" later becomes "onaylandığında", it is already emitted.
function caseA_fullText_confirms_trailing_word() {
  console.log('Case A — full-text path (single segment, repeated)');
  const confirmed: string[] = [];
  const m = newManager(confirmed);
  m.addSpeaker('A', 'Ayse');
  const seg: Seg[] = [{ text: 'proje butcesi onaylandi', start: 0, end: 2 }];
  m.handleTranscriptionResult('A', 'proje butcesi onaylandi', 2, seg); // pass 1: stage
  m.handleTranscriptionResult('A', 'proje butcesi onaylandi', 2, seg); // pass 2: confirm
  m.removeAll();
  assert(confirmed.includes('proje butcesi onaylandi'),
    'CURRENT: whole text confirmed — trailing word NOT held (TR agglutination risk)');
}

// ── Case B: multi-segment Whisper output (word-prefix path) ───────────────────
// When Whisper segments split at word/phrase boundaries, the LocalAgreement
// word-prefix path correctly holds the trailing segment: only the stable prefix
// is emitted, so a suffix change on the last word does not cause a wrong commit.
function caseB_wordPrefix_holds_trailing_word() {
  console.log('Case B — word-prefix path (multi-segment)');
  const confirmed: string[] = [];
  const m = newManager(confirmed);
  m.addSpeaker('B', 'Burak');
  m.handleTranscriptionResult('B', 'proje butcesi onaylandi', 2,
    [{ text: 'proje butcesi', start: 0, end: 1 }, { text: 'onaylandi', start: 1, end: 2 }]);
  m.handleTranscriptionResult('B', 'proje butcesi onaylandiginda gorusuruz', 3,
    [{ text: 'proje butcesi', start: 0, end: 1 }, { text: 'onaylandiginda gorusuruz', start: 1, end: 3 }]);
  m.removeAll();
  assert(confirmed.includes('proje butcesi'),
    'CORRECT: only stable prefix "proje butcesi" emitted');
  assert(!confirmed.some(t => t.includes('onaylandi')),
    'CORRECT: agglutinated trailing word never wrongly committed');
}

// ── Case C: single-word emissions are dropped by the hallucination filter ─────
// Relevant to Turkish: many meaningful single words are flagged as junk, so the
// word-prefix path (which emits one word per stable segment) silently loses
// real content when Whisper returns one word per segment.
function caseC_single_word_filtering() {
  console.log('Case C — hallucination filter vs single Turkish words');
  assert(isHallucination('rapor') === true,
    'DOCUMENTED: single word "rapor" is filtered as hallucination');
  assert(isHallucination('proje butcesi onaylandi') === false,
    'DOCUMENTED: multi-word phrase survives the filter');
}

caseA_fullText_confirms_trailing_word();
caseB_wordPrefix_holds_trailing_word();
caseC_single_word_filtering();

console.log(failures === 0 ? '\nAll assertions passed' : `\n${failures} assertion(s) failed`);
process.exit(failures === 0 ? 0 : 1);
