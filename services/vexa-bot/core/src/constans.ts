// User Agent for consistency - Updated to modern Chrome version for Google Meet compatibility
export const userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";

// Base browser launch arguments (shared across all modes).
const baseBrowserArgs = [
  "--incognito",
  "--no-sandbox",
  "--disable-setuid-sandbox",
  "--disable-features=IsolateOrigins,site-per-process",
  "--disable-infobars",
  "--disable-gpu",
  // Collapse Chromium's gpu-process work into the renderer — no separate
  // gpu-process at all.
  //
  // 2026-04-27 measurement (cycle 260426 Zoom Web): a Zoom Web bot
  // demanded 4.4 cores; 3.6 of those (= 357% CPU) lived in
  // --type=gpu-process running SwiftShader software-WebGL + canvas
  // compositing for Zoom's UI. Software-decoded video frames also flow
  // through that process. With --in-process-gpu, the work collapses
  // into the renderer (which already runs the page's JS) and per-bot
  // demand drops to ~115% — back inside the 1500m budget that matches
  // the gmeet/teams p95 (780m).
  //
  // Earlier iterations on this cycle tried --disable-webgl /
  // --disable-3d-apis / --disable-accelerated-2d-canvas etc.; all
  // confirmed inert (gpu-process kept running because it hosts the
  // software video decoder, not just the compositor).
  // --in-process-gpu is the only flag that actually killed it.
  "--in-process-gpu",
  "--use-fake-ui-for-media-stream",
  "--use-file-for-fake-video-capture=/dev/null",
  "--allow-running-insecure-content",
  "--disable-web-security",
  "--disable-features=VizDisplayCompositor",
  "--ignore-certificate-errors",
  "--ignore-ssl-errors",
  "--ignore-certificate-errors-spki-list",
  "--disable-site-isolation-trials"
];

/**
 * Get browser launch arguments based on voice agent state.
 *
 * When voiceAgentEnabled is false (default):
 *   --use-file-for-fake-audio-capture=/dev/null  → silence as mic input
 *
 * When voiceAgentEnabled is true:
 *   Omit the fake-audio-capture flag so Chromium reads from PulseAudio default
 *   source (virtual_mic remap of tts_sink.monitor), allowing TTS audio into meeting.
 */
/**
 * Get browser launch arguments.
 *
 * All bots use PulseAudio (no /dev/null). Silence is achieved by:
 * - PulseAudio: tts_sink and virtual_mic muted at startup (entrypoint.sh)
 * - Teams UI: mic muted after join (join.ts)
 * - TTS: unmutes pactl + UI mic before speaking, re-mutes after
 */
/**
 * Outbound proxy args for reaching the meeting platform (Teams/Meet/Zoom).
 * Read from env so the SAME image works with or without a proxy. ONLY the
 * browser uses this — the bot's internal HTTP (transcription upload, redis,
 * callbacks) is Node-side and goes direct, never through the proxy.
 *   BOT_PROXY_SERVER  e.g. http://proxy.corp:3128  (https proxy fine; the bot
 *                     already runs with --ignore-certificate-errors)
 *   BOT_PROXY_BYPASS  optional comma-separated hosts that skip the proxy
 */
export function getProxyArgs(): string[] {
  const server = (process.env.BOT_PROXY_SERVER || '').trim();
  if (!server) return [];
  const args = [`--proxy-server=${server}`];
  const bypass = (process.env.BOT_PROXY_BYPASS || '').trim();
  if (bypass) args.push(`--proxy-bypass-list=${bypass}`);
  return args;
}

export function getBrowserArgs(voiceAgentEnabled: boolean = false): string[] {
  return [...baseBrowserArgs, ...getProxyArgs()];
}

/**
 * Browser args for authenticated bot mode (persistent context with stored cookies).
 * Uses minimal, clean flags — aggressive flags like --disable-web-security and
 * --ignore-certificate-errors trigger Google's bot detection and cause "You can't
 * join this video call" blocks. Modeled after getBrowserSessionArgs().
 */
export function getAuthenticatedBrowserArgs(): string[] {
  return [
    '--no-sandbox',
    '--disable-setuid-sandbox',
    '--disable-blink-features=AutomationControlled',
    '--disable-infobars',
    '--disable-gpu',
    '--use-fake-ui-for-media-stream',
    '--use-file-for-fake-video-capture=/dev/null',
    '--disable-features=VizDisplayCompositor',
    '--password-store=basic',
    ...getProxyArgs(),
  ];
}

// Default browser args
export const browserArgs = getBrowserArgs(false);

/**
 * Browser args for interactive browser session mode (VNC + CDP).
 * No incognito, no fake media — human interacts via VNC, agent via CDP.
 */
export function getBrowserSessionArgs(): string[] {
  return [
    '--no-sandbox',
    '--disable-setuid-sandbox',
    '--disable-blink-features=AutomationControlled',
    '--use-fake-ui-for-media-stream',
    '--start-maximized',
    '--window-size=1920,1080',
    '--window-position=0,0',
    '--remote-debugging-port=9222',
    '--remote-debugging-address=0.0.0.0',
    '--remote-allow-origins=*',
    '--password-store=basic',
    ...getProxyArgs(),
  ];
}
