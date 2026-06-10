/**
 * Phase 3 — proves the production transcription path forwards the configured
 * language (and prompt) to transcription-service as multipart form fields.
 * The plumbing already exists in upstream; this guards it against regression.
 * Run: npx tsx src/services/transcription-client.language.test.ts
 */
import { TranscriptionClient } from './transcription-client';

let failures = 0;
function assert(cond: boolean, msg: string) {
  if (!cond) { console.error(`  ✗ ${msg}`); failures++; }
  else { console.log(`  ✓ ${msg}`); }
}

async function main() {
  let asciiBody = '';   // latin1: safe for ASCII field names
  let utf8Body = '';    // utf8: form-field VALUES are UTF-8 encoded by the client
  // Mock fetch: capture the multipart body, return a minimal verbose_json result.
  (globalThis as any).fetch = async (_url: string, init: any) => {
    const buf = Buffer.from(init.body);
    asciiBody = buf.toString('latin1');
    utf8Body = buf.toString('utf8');
    return {
      ok: true,
      status: 200,
      json: async () => ({ text: '', language: 'tr', duration: 0, segments: [] }),
      text: async () => '',
    };
  };

  const client = new TranscriptionClient({ serviceUrl: 'http://svc' });
  await client.transcribe(new Float32Array(1600), 'tr', 'önceki onaylanan metin');

  console.log('Phase 3 — language plumbing to transcription-service');
  assert(asciiBody.includes('name="language"'), 'language form field is present');
  assert(/name="language"\r\n\r\ntr\r\n/.test(asciiBody), 'language value is "tr"');
  assert(asciiBody.includes('name="prompt"'), 'prompt (context bias) form field is present');
  assert(utf8Body.includes('önceki onaylanan metin'),
    'prompt value is forwarded with correct UTF-8 (Turkish chars intact)');
  assert(asciiBody.includes('name="response_format"\r\n\r\nverbose_json'),
    'verbose_json requested (needed for segment-level confirmation)');

  console.log(failures === 0 ? '\nAll assertions passed' : `\n${failures} assertion(s) failed`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
