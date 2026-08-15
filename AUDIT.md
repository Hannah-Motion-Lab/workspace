# Hannah project audit — 2026-08-15

**Scope:** the 4 repos (backend, frontend, desktop, motion-lab) + launcher + configs (~9.6k lines).
**Method:** 10 automated auditors in parallel (duplication, Node/React practices, over-engineering,
Python, security, consistency, tests) → 101 findings → dedup → **manual verification of the
critical ones against the real code**.
**Result:** 6 critical, ~35 medium, ~45 minor (after dedup). Nothing was modified.

> **Severity context.** Hannah is self-hosted, single user, on localhost. Several security
> "criticals" **only bite if the backend ends up exposed on the network or once the repo goes public** —
> but that is exactly what you have planned, and the backend **listens on `0.0.0.0` today** (the whole LAN). So
> they are priority #1 before sharing. The rest (duplication, dead code, perf) is the normal technical debt
> of a project that grew fast.

---

## Executive summary

**Overall health: good and pragmatic, with debt concentrated in 4 hotspots.** The code works, the
deterministic layers + tags + skills coexist on purpose (good). The real debt:

1. **Network exposure** — `express.static('.')` gives away `data/settings.json` (API keys) and `data/memory.db`
   (your whole history), the terminal pty runs a shell with no gate and no auth, and everything listens on `0.0.0.0`.
2. **Dead code from the pivots** — the anime/smplx toggle was left half-removed and drags along a **19 MB preload
   on every start**, plus `toolSchemas`/`cmdAllowlist`/`trustModel`/`recall_memory`/Tauri leftovers.
3. **Duplication** — 4 state modules with the same `load/persist`, the action-tag list in 2
   hand-written regexes, move parsing copied between backend and Electron, 10 identical `catch`es in the API.
4. **A codebase with no safety net** — 0 ESLint, and the regex-heavy layer (intent parsers, DANGER) **without a
   single test**; worse: the current test **corrupts your real memory** when it runs.

### Top 6 actions (maximum impact / minimum effort)

| # | Action | Covers | Effort |
|---|--------|------|----------|
| 1 | `express.static('public')` instead of `'.'` + `app.listen(port, '127.0.0.1')` | 2 criticals (keys+memory on the LAN) | S |
| 2 | `open_url`: `execFile('xdg-open',[u])` + validate with `new URL(u)` | 1 critical (RCE via injection) | S |
| 3 | Gate `TERMINAL_START/IN` with `systemControl` (+ the bind from point 1) | 1 critical (shell with no auth) | S |
| 4 | Remove the `logger.info("ASR result: …")` from the ASR sidecar | 1 critical (privacy) | S |
| 5 | Delete dead code (smplx/rpm avatars + 19MB preload, toolSchemas/names, cmdAllowlist, trustModel, recall_memory, Tauri) | ~500 lines + 19MB | M |
| 6 | `lib/api.js` with `API_BASE` for the frontend's 10 fetches | panels broken in Electron + dedup | S |

---

## 🔴 Critical (verified against the code)

### C1 · `express.static('.')` exposes API keys and history over the network
`hannah-backend/src/server.js:48` + `:68`
```js
app.use(express.static('.'));          // serves the WHOLE backend root
const httpServer = app.listen(config.port, () => { … });  // no host -> 0.0.0.0
```
**Why it matters:** `GET /data/settings.json` returns the config with `apiKey` in **plain text**
(`snapshot()` in `state/settings.js:66` writes the secret unredacted) and `GET /data/memory.db`
downloads **5.5 MB of every conversation you have had**. The `/settings` endpoint is careful to redact the key…
but the static handler gives it away anyway. And since it listens on `0.0.0.0`, any machine on the LAN can read it (curl does
not go through CORS). Today your `llm.apiKey` is `"ollama"` (harmless), but the moment you use a Groq/OpenAI key
it is exposed — and the memory already is.
**Fix (S):** serve only what is public → `app.get('/test-client.html', (req,res)=>res.sendFile(…))` or
`express.static('public')`; and `app.listen(config.port, '127.0.0.1')` (host configurable).

### C2 · Command injection in `open_url` (RCE with no flag at all)
`hannah-backend/src/pipeline/tools.js:94`
```js
exec(`${opener} "${u}"`, …);   // the URL goes raw into the shell, inside quotes
```
**Why it matters:** `u` is only validated with `/^https?:\/\//` and is interpolated into an `exec()` (which uses `/bin/sh`).
A URL with a quote escapes: `https://x";touch /tmp/pwned;"`. `open_url` is **not** behind
`systemControl` nor behind `DANGER`: it fires from the model's `[BROWSE:]` tag and from `handleOpenIntent`.
Real chain: malicious page read with `fetch_url`/`web_search` → prompt injection → the model emits
`[BROWSE: <payload>]` → code execution. It is the worst path of all, because nothing has to be turned on for it to work.
**Fix (S):** `execFile('xdg-open', [u])` (no shell) + `new URL(u)` rejecting schemes ≠ http/https.

### C3 · Terminal (pty) = shell with no authentication and no `systemControl` gate
`hannah-backend/src/gateway/websocket.js:112` → `terminal.js:39`
```js
case 'TERMINAL_IN': terminalInput(sessionId, data.data || ''); break;
// terminal.js: input(sessionId,data){ sessions.get(sessionId)?.pty.write(data); }
```
**Why it matters:** `TERMINAL_START` creates a login pty (`$SHELL -l`) **without ever looking at `systemControl`**
(that flag only protects `run_command` and `terminal` skills). With `POST /session` unauthenticated + the `0.0.0.0` bind,
any device on the LAN can open the WS and **type arbitrary commands into your shell** — the `DANGER`/
confirmation does not apply to this path either. "system control off" does NOT guarantee that no shell runs.
**Fix (S):** gate `TERMINAL_START/IN/RESIZE` with `systemControl` **and** bind to `127.0.0.1` (C1). Document
that the terminal channel is equivalent to shell access.

### C4 · The ASR sidecar logs the user's transcript (violates the privacy rule)
`hannah-backend/sidecar/asr/main.py:75`
```py
logger.info(f"ASR result: {transcript[:80]}")
```
**Why it matters:** CLAUDE.md is explicit — *"Never log user content (transcripts, LLM responses)"*.
Every sentence you say ends up written into the log (journald/persistent stdout). It is the only sidecar that breaks
the guarantee. (There is also a twin violation in `websocket.js:85`, which logs the client's raw payload.)
**Fix (S):** `logger.info(f"ASR done: {len(transcript)} chars, lang={info.language}")`.

### C5 · The Settings/Shortcuts/Skills panels use relative `fetch` → broken in the Electron app
`hannah-frontend/src/components/SettingsPanel.jsx` (10 calls: 100, 150, 170, 237, 242, 248, 260, 269, 342, 377)
```js
fetch('/api/v1/settings')   // vs useWebSocket.js: API_BASE = DESKTOP ? DESKTOP.backendBase : ''
```
**Why it matters:** in packaged Electron the page is served from the mini static server in
`main.js` (random port, no proxy). A `fetch('/api/v1/…')` resolves against that origin and gives 404 →
every section falls into "backend no disponible". **Settings, Shortcuts, Skills and the voice picker do not work
in the desktop app** (only in the browser via the Vite proxy). Root cause: the fetch pattern is copied
10 times with no helper, so the `API_BASE` that *was* added in `useWebSocket.js` never propagated.
**Fix (S):** `src/lib/api.js` with `API_BASE` + `apiGet/apiPost/apiDelete`; replace the 10 calls.

### C6 · `npm test` writes into your REAL memory and can call Ollama live
`hannah-backend/tests/unit/conversationManager.test.js:26`
**Why it matters:** `addTurn` persists to the real SQLite (`memoryStore` opens `data/memory.db` with a
hardcoded path, no override for tests). Every `npm test` inserts "turno N" rows into your long-term
memory; with `MEMORY_RECALL` on by default it fires embeddings at Ollama, and once the summary threshold is crossed
it **rewrites your persistent summary**, folding in test garbage. The test passes, but it **corrupts real data**.
**Fix (S):** injectable DB path (`MEMORY_DB_PATH=':memory:'` in tests) + `MEMORY_RECALL=false` in the setup.

---

## 🟡 Medium (grouped by theme)

### Security / robustness
- **DANGER is an evadable blocklist** (`tools.js:17`). It is the only gate between the LLM and destructive commands
  with `systemControl=true`, and it is bypassed trivially: `\brm\s+\S` does not match `ls | xargs rm` nor `find . -delete`,
  `shred`, `truncate -s0`, `> archivo`, `: > f`, nor `base64|sh`/`eval`. **Fix (M):** either confirmation for EVERY
  `run_command`, or make it explicit that DANGER is best-effort (not a barrier).
- **Skills' `{arg}` is interpolated raw into the shell** (`skills.js:139`) → injection with `;`/`$()`/pipes. Gated
  by `systemControl`, but turning that on + injection = RCE. **Fix (M):** `execFile`/shell-quote, or always treat
  `run` with `{arg}` as destructive (confirm).
- **SSRF in `fetch_url`/`web_search`** (`tools.js:72`): they reach `127.0.0.1:11434` (Ollama), `:8005` (motion),
  the LAN and cloud metadata (169.254.169.254). A web page read earlier can make Hannah read her own internal
  endpoints. **Fix (M):** reject loopback/private/link-local before the fetch.
- **WS with no `maxPayload` and no type validation** (`websocket.js:14`): the 5MB cap only covers binary; `data.frame`
  and `data.text` are not validated. **Fix (S).**
- **Electron `webSecurity:false` + `no-sandbox`** (`main.js:48`): accepted risk, but **document it**.

### Duplication (consolidate)
- **Deterministic layer copied** between `processVoiceTurn` and `processUserTextTurn` (`orchestrator.js:161` vs 231):
  ~14 nearly identical lines + the magic string *"(Responde al usuario con este resultado real…)"* twice.
  **Fix (S):** a `runDeterministicLayer(text, …)` helper.
- **Action-tag list in 2 hand-written regexes** (`llm.js:113` `ACTION_RE` vs `orchestrator.js:74` strip): if
  you add a tag and forget the strip, **the TTS reads it out loud**. **Fix (S):** derive both from `Object.keys(ACTION_TOOL)`.
- **DANGER→confirm gate duplicated** between `run_command` (`tools.js:162`) and `terminal` skills (`skills.js:159`).
  This is security: if they diverge, one path confirms differently. **Fix (S):** `confirmIfDangerous(cmd, ctx)`.
- **JSON persistence duplicated** between `settings.js` and `shortcuts.js` (identical `persist/load`) + `DATA_DIR`
  computed in 4 modules. **Fix (S):** `state/dataDir.js` + `jsonFile(name)`.
- **10 identical `catch → res.status(500)`** in `api/*.js` even though there is a global error middleware in
  `server.js:54` doing the same thing (it is never reached). **Fix (S):** a `handler(slug, fn)` wrapper.
- **Vector recall duplicated** between `recallContext` (`llm.js:21`) and the `recall_memory` tool (`tools.js:32`),
  **with diverging thresholds** (0.55 vs 0.5, configured K vs 3). **Fix (S):** `recallTopK()` in `embeddings.js`.
- **backend `windowControl.js` ↔ `hannah-desktop/main.js`**: parsing of move specs and gaze (K=1.4,
  eyeY=0.32, COMPACT 400×620) copied and **already diverged**. **Fix (M):** the backend sends the resolved spec.
- **Avatars:** `VrmAvatar` and `SmplxAvatar` copy the frame computation and the axis-angle→quaternion decode
  (`VrmAvatar.jsx:242` vs `SmplxAvatar.jsx:66`). **Fix (S):** `lib/motionUtils.js`.
- **Memoized OpenAI client** repeated in `llm.js:33` and `vlm.js:8` (vlm does not invalidate on apiKey). **Fix (S).**
- **`preload_cuda_libs()` copied** char-for-char between `asr/main.py` and `tts/main.py`. **Fix (S):** `sidecar/common.py`.
- Minor ones of the same kind: `sh` in hyprland/x11, motion envelope (lab/emage), HTML strip in fetch_url/web_search,
  `ensureHttps` in 2 tools, base64→bytes in useWebSocket, `CLOSE_ALIAS`, HUD buttons that ignore `IconBtn`.

### Dead code / over-engineering
- **`avatarMode` is zombie state:** `setAvatarMode` has no caller at all; it is `'vrm'` forever. It leaves
  `Avatar.jsx` (113 lines), `SmplxAvatar.jsx` (124) dead and **a 19 MB `useGLTF.preload('/smplx_avatar.glb')`
  that is downloaded on EVERY overlay start** (`SmplxAvatar.jsx:123`). **Fix (M):** delete both + the
  preload + `VISEME_MAP` + `avatarMode` from the store.
- **`toolSchemas()` is dead code** from the old function-calling (`tools.js:323`): `llm.js` imports it but
  never calls it → **`config.tools.names` and the `TOOLS` env filter nothing** (every tool is reachable
  through tags). **Fix (S):** delete.
- **`cmdAllowlist`** (`config.js:146`) has no consumer and its comment *"con allowlist"* **is false** — with
  `systemControl=true` any command runs. Config that misinforms about the real risk. **Fix (S):** delete.
- **`skills.trustModel`** (`config.js:157`): editable and persisted from the ⚙ panel, but **no code
  reads it** (the deterministic layer runs unconditionally). UI that lies to the user. **Fix (S):** delete or implement.
- **`recall_memory` / `[RECALL:]`**: the tool exists but no prompt teaches it and the config itself says it is
  omitted. It duplicates `recallContext`. **Fix (S):** delete the tool and `RECALL` from the regexes.
- **Tauri leftovers:** `const isTauri` in `App.jsx:11` (dead) + `@tauri-apps/api`/`cli` in devDeps with no
  `src-tauri/`. **Fix (S):** delete.
- **`motion` config half-migrated** (`config.js:118`): a single `sidecarUrl` for two incompatible providers;
  `.env.example` pins `:8004` (EMAGE) while the default provider is `lab` (:8005) → **co-speech gestures fail
  silently** with the documented setup. **Fix (S):** separate URLs per provider.
- Minor: `getReference()` with no consumer, `motion.js` `action`/`intensity` that nobody passes, `pushFrame` pass-through
  of `frameStore`, double `analyzeScene/analyzeFrame` wrapper, dead state in the store (`lastDetection`, `sessionId`).

### React / performance
- **`HUD.jsx:76` and `App.jsx:48` subscribe to the store WITHOUT a selector.** Zustand notifies on any change, and
  during speech `setVisemes` fires several times/sec + `overlayGaze` at ~12 Hz + `addLog` per event →
  **the HUD and the whole tree (Scene/Canvas included) re-render 20+ times/sec**. **Fix (S):** atomic selectors
  (`useHannahStore(s => s.emotion)`). It is the highest-impact perf fix. (Also, `HUD` destructures `logs` it does not use.)
- **Race in `connect()`** (`useWebSocket.js:259`): after the fetch's `await` it does not check `unmountedRef` → under
  StrictMode it creates an orphan WebSocket that stays open forever and can reconnect on its own. **Fix (S).**
- **The viseme reset timer (120ms) is not registered** in `visemeSchedule` (`useWebSocket.js:64`): it survives
  barge-in (stomping the first viseme of the next sentence) and the id array is never emptied. **Fix (S).**
- **`useWebSocket.js` (332 lines) mixes 5 non-React responsibilities** (transport, audio engine, viseme
  scheduler, motion decode, router). **Fix (M):** extract `lib/audioPlayer.js` + `lib/wsClient.js`.
- Minor: `useVision` does not clean up the interval/camera on unmount (it creates a 640×480 canvas every 2s); `onGaze` IPC
  with no cleanup (double registration under StrictMode); `Avatar.jsx` rebuilds Sets on every frame; `GAZE_ON` is sent twice.

### Correctness (subtle bugs)
- **`handleOpenIntent`/`handleCloseIntent` (async) are called with no `await` and no `.catch`** (`orchestrator.js:165`,
  235). A throw = `unhandledRejection` → **it takes the process down** (violates "never crash"). Same for `moveWindow()`
  at 66/164/234. And the boolean they return is ignored → the model can re-open the app via `[OPEN:]`. **Fix (S).**
- **With tools active, per-sentence pipelining is lost** (`llm.js:129`): the response comes in whole as ONE
  segment → a single giant TTS call, time-to-first-audio = the full generation. It breaks the <500ms target
  and "stream at every stage" on every turn. **Fix (S):** split by sentence in the no-actions path too.
- **The `recentUserMove` Map grows without bound** per sessionId (`orchestrator.js:49`); same for `_session_prefix` in
  `motion-lab/serve/main.py:39` (it holds CUDA tensors per session forever). **Fix (S):** TTL/LRU.
- **`/text` with no `error` handler on the audioStream** (`router.js:53`): if the stream fails the request hangs
  forever. **Fix (S).**

### Python (sidecars + motion-lab)
- **`async def` endpoints with synchronous inference** block the event loop in all 4 sidecars (`/health` does not
  respond during each inference; concurrent requests get serialized). **Fix (S):** declare them `def` (FastAPI
  hands them to the threadpool) or `run_in_executor`.
- **Vision does not validate its input** (`vision/main.py:21`): corrupt base64/image → raw 500 instead of 400 (the
  other sidecars do return 400). **Fix (S).** Also: no `/health`, `print()` instead of logging, uploads with no
  size limit.
- **`train_vae.py`/`train_flow.py` duplicate ~60 lines** of scaffolding that has already diverged (NaN threshold 1e3 vs 1e4). **Fix (M).**
- Minor: T5 and models loaded on the first request (not at startup); `requirements.txt` with mixed pins
  (`ultralytics`/`pillow` unpinned); checkpoint resume that does not restore the optimizer.

### Config / contracts / docs
- **`process.env` outside `config.js`** in `terminal.js:15` (SHELL/COMSPEC), `hyprland.js:16`, `x11.js:10`
  (violates the rule). **Fix (S).**
- **Stale docs:** README/CLAUDE.md/.env.example say things that are no longer true (Hannah "speaks
  Spanish" vs the protocol in English; the motion section as "EMAGE :8004"; tools "OFF by default" vs an `.env` with
  `TOOLS_ENABLED=true`). *(The consistency auditor was cut off by the session limit — this comes from the other auditors;
  a dedicated pass is advisable.)*

### Tests / tooling
- **0 ESLint** in the 3 JS repos (no config, no script, no devDep). It would catch the `no-unused-vars`,
  `react-hooks/exhaustive-deps` and fire-and-forget items above for free. **Fix (S).**
- **The regex-heavy layer does not have a single test:** `parseMoveIntent`, `resolveDataAction`/`handleOpen`/`handleClose`,
  `parseFrontmatter`/`sshArg`/`resolveSkillPhrase`, the orchestrator's tag strip, and **the `DANGER` guard**
  (the one thing that decides whether confirmation is asked before an `rm`). They are pure functions: the cheapest and
  highest-value test in the repo. **Fix (S–M):** table-driven `string → expected` suites.
- **`llm.test.js`** starts from an obsolete premise (the OpenAI client is no longer instantiated on import). Review.
- **Declared but unused deps:** `@anthropic-ai/sdk`, `supertest`, `@tauri-apps/*`. **Fix (S).**

---

## ⚪ Minor (45) — summary
Almost all of them are **small duplication** (copied helpers: `sh`, base64→bytes, `ensureHttps`, `stripHtml`, motion
envelope, the `[Salida real de…]` format), **repeated magic numbers** (the `-1.6` floor in 4 files; inline palette/typography
with no tokens module), **dead pass-throughs** (`visionLoop` re-exports `frameStore`), and **robustness
polish** (`get_weather` with no timeout, `console.error` instead of the logger, the launcher with fragile steps). None
urgent; they get swept little by little, or along with whatever refactor touches the area they belong to. Full list in the
workflow journal.

---

## Next steps (proposed batches)
1. **Security (before exposing/publishing):** C1–C4 + the terminal gate + SSRF. ~1 session, almost all S.
2. **Dead-code sweep:** avatars+19MB preload, toolSchemas/names, cmdAllowlist, trustModel, recall_memory,
   Tauri, zombie state in the store. Trims ~500 lines + 19MB. Low risk.
3. **React perf + Electron:** store selectors, `lib/api.js` (fixes the panels), the connect race, viseme timers.
4. **Structural dedup:** `dataDir`/`jsonFile`, the API error wrapper, action tags from a single source,
   `motionUtils`, the orchestrator's deterministic layer, `sidecar/common.py`.
5. **Safety net:** ESLint in the 3 repos + table-driven tests for the regex/DANGER layer + fix for the test that
   corrupts memory.
6. **Docs:** consistency pass (README/CLAUDE.md/.env.example).

*Tell me which batch to start with (or individual findings) and I'll apply it in separate commits as pedrochgdev.*
