# Diagnostics playbook

Where to look when something fails, and the causes already seen. Written for whoever debugs an
installed copy (a person or Claude Code), on any OS. Read this before touching code.

## Layout of an installed copy

`HANNAH_HOME` (default `~/Hannah-Motion`, Windows `%USERPROFILE%\Hannah-Motion`) holds the five repos
(`hannah-backend`, `hannah-frontend`, `hannah-desktop`, `hannah-motion-lab`, `hannah-agent`), the
launcher (`hannah` / `hannah-mac` / `hannah.ps1` + `hannah.cmd`) and the logs. The overlay app is
separate: Linux `~/.local/bin/Hannah.AppImage`, macOS `~/Applications/Hannah.app`, Windows
`%LOCALAPPDATA%\Programs\Hannah\Hannah.exe`. Runtime config and memory: `hannah-backend/data/`
(`settings.json` holds API keys: never paste it anywhere).

Ports: backend 3001, Vite 5173 (Linux dev only), ASR 8001, TTS 8002, motion 8005, agent 8006,
sense 8007, Ollama 11434. Health: `http://localhost:3001/api/v1/health`, sidecars `/health`,
motion `/health` returns `ready` (false while warming up: minutes on CPU, normal).

## Logs

| OS | Launch + backend log | Per-service logs | App (Chromium/renderer) log |
|----|----------------------|------------------|-----------------------------|
| Linux | `.hannah-launch.log` (everything) | same file | none by default (run the AppImage with `--enable-logging=stderr`) |
| macOS | `.hannah-launch.log` | same file | none by default |
| Windows | `.hannah-launch.log` | `.hannah-logs\<svc>.out.log` / `.err.log` | `.hannah-logs\app.log` |

`hannah doctor` prints what is up, what is missing and the last lines of the error log of any
service that is down. Start there, always.

## One conversation turn in the backend log (what a healthy turn looks like)

```
Usuario empezó a hablar, limpiando buffers...    <- VAD saw speech start (client side)
Usuario terminó de hablar. Procesando turno...   <- VAD saw the end, audio arrived
Iniciando transcripción ASR...  /  ASR done: N chars, lang=xx
Despertando cerebro LLM... {"model":"..."}       <- request to the brain
POST /v1/audio/speech 200 OK                     <- TTS per sentence
Motion generado {"frames":..}                    <- gestures per sentence
```
The first line missing after each of these tells you which stage died.

## Symptom -> where -> known causes

**She does not listen (no reaction at all).**
- No `Usuario empezó a hablar` ever: the mic never reaches the page. Check the red mic banner in the
  overlay, OS mic permission for the app, and `app.log` for `NotAllowedError` / `getUserMedia`.
- `empezó` but never `terminó`: the VAD never closed the utterance. Cause seen: silence threshold
  below the speech threshold, background noise kept it open forever (fixed in frontend
  `hooks/useVoiceActivity.js`: `negativeSpeechThreshold` = `positiveSpeechThreshold`, options in ms
  because `@ricky0123/vad-web` 0.0.30 ignores the old `*Frames` names). If it returns, look at
  those options first; do not add timers, the end of speech is silence.
- `terminó` but ASR timeout: CPU Whisper takes 5 to 9 s per phrase; `ASR_TIMEOUT_MS` (default
  60000) and voice turns are serialized per connection, so overlapping speech waits, not fails.

**She listens (transcript in the log) but never answers.**
- `Despertando cerebro` followed by nothing or `runtime error 404 ... does not exist`: the model id
  is gone. Groq retires ids often (`llama-3.1-8b-instant`, `llama-3.3-70b-versatile` are gone;
  current default `openai/gpt-oss-20b`). Check with the user's key:
  `GET <baseUrl>/models` (Authorization: Bearer). The ⚙ panel and the welcome screen validate the
  model against the provider before saving and list what exists; a runtime LLM error is sent to
  the client as `{type:'error', code:'llm'}` and reopens the brain screen.
- HTTP 200 but empty content, `finish_reason: length`, 10 to 50 s latency: a reasoning model
  (Gemini 3.x flash, o-series) spends the token budget thinking. Use a non-reasoning model
  (`gemini-2.5-flash`, `gemini-flash-lite-latest`, `openai/gpt-oss-20b`, `qwen/qwen3.8-27b`).
- Cloudflare-fronted providers (Groq, OpenRouter) answer 403 `error code: 1010` to a Python
  `urllib` user agent: test with curl or set a browser-like `User-Agent`.

**Avatar in T-pose (arms straight out) or arms up.**
- The retarget offsets are computed at load from the normalized rig, which must be at rest when
  sampled; drei caches the VRM object by URL, so a second rig build measured an already posed
  model (fixed in `src/retarget/offsets.js`: `resetNormalizedPose` + `resetRawPose` before
  sampling). Inspect in DevTools / CDP: `window.__hannahVrm.offsets['16'].dir` must be `-1,0,0`
  for the stock VRoid; the left hand world y must be about -0.65 at rest (T-pose: -0.25, up: +0.16).
- If the whole frame loop is stopped (HUD alive, avatar frozen): Chromium throttled an occluded
  window. The desktop app sets `backgroundThrottling: false` and the occlusion switches
  (`hannah-desktop/main.js`); check `requestAnimationFrame` runs at 60 fps.

**Gestures missing (`motion missing` in doctor, `audio_chunk` without `motion`).**
- `/health` on 8005 with `ready: false`: warming up (85 s on a Windows CPU); wait.
- Not running: `motion.err.log`. Seen: missing `src/motionlab/data` package (was gitignored),
  missing serve deps (`requirements-serve.txt`), no weights in `hannah-motion-lab/runs/*/latest.pt`
  (they come from the `models` release of `motion-model`).
- `MOTION_DEVICE=auto` picks cuda > mps > cpu; motion is never skipped for being slow.

**Overlay does not close / two overlays.** `hannah stop` kills the app by its real executable
path (AppImage runtime + `/tmp/.mount_Hannah*/`, `Hannah.app`, `Hannah.exe`) and the services by
port. The app holds a single-instance lock: a second launch focuses the first.

**Doctor says `vite (port busy)` while Vite works.** Vite binds `localhost`, which can be IPv6
only; probe `localhost`, not `127.0.0.1` (fixed in the Linux launcher).

**Avatar upload: `Failed to fetch`.** CORS preflight refused `PUT` (fixed: `server.js` methods).
Other causes: not a VRM (400 `not_a_vrm`), over `MAX_AVATAR_BYTES`.

**Terminal panel empty / `terminal_disabled`.** Tools are off by default; ⚙ -> Manos ->
"Puede actuar en este PC: si" (`tools.systemControl`).

**Windows install / launcher quirks already handled.** PowerShell 5.1 mangles non-ASCII (scripts
are ASCII only, keep them so), native stderr is fatal under `$ErrorActionPreference = 'Stop'`
(scripts use `Continue`), `$args` is an automatic variable (never a parameter name), NSIS
per-user install lands in `%LOCALAPPDATA%\Programs\Hannah` (found via the Uninstall registry key),
downloaded scripts need `Unblock-File`, PATH changes need a new terminal.

## Quick checks without the UI

```bash
curl -s localhost:3001/api/v1/health          # services, tools, agent, brain mode
curl -s localhost:8005/health                 # {"device":"cuda","ready":true}
curl -s localhost:3001/api/v1/brain           # configured?, ollama models, recommendation
```
A full text turn over the WebSocket (run inside `hannah-backend`, prints each stage with timing):
```bash
node --input-type=module <<'EOF'
import WebSocket from 'ws';
const { sessionId } = await (await fetch('http://127.0.0.1:3001/api/v1/session', { method: 'POST' })).json();
const ws = new WebSocket(`ws://127.0.0.1:3001/ws?sessionId=${sessionId}`); const t0 = Date.now();
ws.on('open', () => ws.send(JSON.stringify({ command: 'TEXT_INPUT', text: 'hello, how are you today?' })));
ws.on('message', (m) => { if (Buffer.isBuffer(m) && m[0] !== 0x7b) return; const d = JSON.parse(m.toString());
  const dt = ((Date.now() - t0) / 1000).toFixed(1);
  if (d.type === 'audio_chunk') console.log(dt, 'audio_chunk', 'audio', !!d.audioBase64, 'motion', !!d.motion);
  else if (d.type === 'turn_complete') { console.log(dt, 'turn_complete', d.emotion); process.exit(0); }
  else console.log(dt, d.type, d.code || '', d.message || ''); });
setTimeout(() => { console.log('timeout'); process.exit(1); }, 60000);
EOF
```
Expected: `audio_chunk audio true motion true` within a few seconds, then `turn_complete`.

## Where behavior is decided (read these, not the whole tree)

- Voice capture and VAD: `hannah-frontend/src/hooks/useVoiceActivity.js`; WS client and playback:
  `src/hooks/useWebSocket.js`; avatar and retarget: `src/components/VrmAvatar.jsx`, `src/retarget/`.
- Turn pipeline: `hannah-backend/src/gateway/websocket.js` -> `src/pipeline/orchestrator.js` ->
  `asr.js`, `llm.js`, `tts.js`, `motion.js`. Brain choice and validation: `src/pipeline/brain.js`,
  `src/api/brain.js`, `src/api/settings.js`. Config: `src/config.js` only.
- Overlay window: `hannah-desktop/main.js`. Launchers: `hannah`, `hannah-mac`, `hannah.ps1`.
- Motion server: `hannah-motion-lab/serve/main.py` (`pick_device`, warm-up, `/health`).

Rules that still bind while fixing anything: never log user content (transcripts, replies), never
write audio to disk, stream every stage, fail per stage with `{type:'error'}` instead of crashing,
motion is never skipped for latency, everything must fit in 16 GB of VRAM.
