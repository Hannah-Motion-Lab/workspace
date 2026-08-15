# Auditoría del proyecto Hannah — 2026-08-15

**Alcance:** los 4 repos (backend, frontend, desktop, motion-lab) + launcher + configs (~9.6k líneas).
**Método:** 10 auditores automáticos en paralelo (duplicación, prácticas Node/React, sobreingeniería,
Python, seguridad, consistencia, tests) → 101 hallazgos → dedup → **verificación manual de los
críticos contra el código real**.
**Resultado:** 6 críticos, ~35 medios, ~45 menores (tras dedup). No se modificó nada.

> **Contexto de severidad.** Hannah es self-hosted, un usuario, en localhost. Varios "críticos" de
> seguridad **solo muerden si el backend queda expuesto en red o cuando el repo se haga público** —
> pero justo eso está en tus planes, y el backend **hoy escucha en `0.0.0.0`** (toda la LAN). Así que
> son la prioridad #1 antes de compartir. El resto (duplicación, código muerto, perf) es deuda técnica
> normal de un proyecto que creció rápido.

---

## Resumen ejecutivo

**Salud general: buena y pragmática, con deuda concentrada en 4 focos.** El código funciona, las capas
deterministas + tags + skills conviven a propósito (bien). La deuda real:

1. **Exposición de red** — `express.static('.')` regala `data/settings.json` (API keys) y `data/memory.db`
   (todo tu historial), el pty de terminal corre shell sin gate ni auth, y todo escucha en `0.0.0.0`.
2. **Código muerto de los pivots** — el toggle anime/smplx quedó a medio quitar y arrastra un **preload
   de 19 MB en cada arranque**, más `toolSchemas`/`cmdAllowlist`/`trustModel`/`recall_memory`/restos de Tauri.
3. **Duplicación** — 4 módulos de estado con el mismo `load/persist`, la lista de tags de acción en 2
   regex a mano, el parseo de movimiento copiado entre backend y Electron, 10 `catch` idénticos en la API.
4. **Base sin red de seguridad** — 0 ESLint, y la capa regex-heavy (parsers de intents, DANGER) **sin un
   solo test**; peor: el test actual **corrompe tu memoria real** al correr.

### Top 6 acciones (máximo impacto / mínimo esfuerzo)

| # | Acción | Tapa | Esfuerzo |
|---|--------|------|----------|
| 1 | `express.static('public')` en vez de `'.'` + `app.listen(port, '127.0.0.1')` | 2 críticos (keys+memoria en LAN) | S |
| 2 | `open_url`: `execFile('xdg-open',[u])` + validar `new URL(u)` | 1 crítico (RCE por inyección) | S |
| 3 | Gatear `TERMINAL_START/IN` con `systemControl` (+ el bind del punto 1) | 1 crítico (shell sin auth) | S |
| 4 | Quitar el `logger.info("ASR result: …")` del sidecar ASR | 1 crítico (privacidad) | S |
| 5 | Borrar código muerto (avatares smplx/rpm + preload 19MB, toolSchemas/names, cmdAllowlist, trustModel, recall_memory, Tauri) | ~500 líneas + 19MB | M |
| 6 | `lib/api.js` con `API_BASE` para los 10 fetch del frontend | panels rotos en Electron + dedup | S |

---

## 🔴 Críticos (verificados contra el código)

### C1 · `express.static('.')` expone API keys e historial por la red
`hannah-backend/src/server.js:48` + `:68`
```js
app.use(express.static('.'));          // sirve TODO el root del backend
const httpServer = app.listen(config.port, () => { … });  // sin host -> 0.0.0.0
```
**Por qué importa:** `GET /data/settings.json` devuelve la config con `apiKey` en **texto plano**
(`snapshot()` en `state/settings.js:66` escribe el secreto sin redactar) y `GET /data/memory.db`
descarga **5.5 MB de todas tus conversaciones**. El endpoint `/settings` se cuida de redactar la key…
pero el static la regala igual. Y como escucha en `0.0.0.0`, cualquier equipo de la LAN la lee (curl no
pasa por CORS). Hoy tu `llm.apiKey` es `"ollama"` (inofensivo), pero apenas uses una key de Groq/OpenAI
queda expuesta — y la memoria ya lo está.
**Fix (S):** servir solo lo público → `app.get('/test-client.html', (req,res)=>res.sendFile(…))` o
`express.static('public')`; y `app.listen(config.port, '127.0.0.1')` (host configurable).

### C2 · Inyección de comandos en `open_url` (RCE sin ningún flag)
`hannah-backend/src/pipeline/tools.js:94`
```js
exec(`${opener} "${u}"`, …);   // la URL va cruda al shell, entre comillas
```
**Por qué importa:** `u` solo se valida con `/^https?:\/\//` y se interpola en un `exec()` (usa `/bin/sh`).
Una URL con comilla escapa: `https://x";touch /tmp/pwned;"`. `open_url` **no** está detrás de
`systemControl` ni de `DANGER`: se dispara con el tag `[BROWSE:]` del modelo y desde `handleOpenIntent`.
Cadena real: web maliciosa leída con `fetch_url`/`web_search` → inyección de prompt → el modelo emite
`[BROWSE: <payload>]` → ejecución de código. Es la vía más grave porque no requiere activar nada.
**Fix (S):** `execFile('xdg-open', [u])` (sin shell) + `new URL(u)` rechazando esquemas ≠ http/https.

### C3 · Terminal (pty) = shell sin autenticación ni gate `systemControl`
`hannah-backend/src/gateway/websocket.js:112` → `terminal.js:39`
```js
case 'TERMINAL_IN': terminalInput(sessionId, data.data || ''); break;
// terminal.js: input(sessionId,data){ sessions.get(sessionId)?.pty.write(data); }
```
**Por qué importa:** `TERMINAL_START` crea un pty de login (`$SHELL -l`) **sin mirar `systemControl`**
(ese flag solo protege `run_command` y skills `terminal`). Con `POST /session` sin auth + bind `0.0.0.0`,
cualquier dispositivo de la LAN abre el WS y **tipea comandos arbitrarios en tu shell** — el `DANGER`/
confirmación tampoco aplica a esta vía. "system control off" NO garantiza que no se corra shell.
**Fix (S):** gatear `TERMINAL_START/IN/RESIZE` con `systemControl` **y** bindear a `127.0.0.1` (C1). Documentar
que el canal terminal equivale a acceso shell.

### C4 · El sidecar ASR loguea el transcript del usuario (viola regla de privacidad)
`hannah-backend/sidecar/asr/main.py:75`
```py
logger.info(f"ASR result: {transcript[:80]}")
```
**Por qué importa:** el CLAUDE.md es explícito — *"Never log user content (transcripts, LLM responses)"*.
Cada frase que decís queda escrita en el log (journald/stdout persistente). Es el único sidecar que rompe
la garantía. (Además hay una violación gemela en `websocket.js:85`, que loguea el payload crudo del cliente.)
**Fix (S):** `logger.info(f"ASR done: {len(transcript)} chars, lang={info.language}")`.

### C5 · Los paneles de Ajustes/Atajos/Skills usan `fetch` relativo → rotos en la app Electron
`hannah-frontend/src/components/SettingsPanel.jsx` (10 llamadas: 100, 150, 170, 237, 242, 248, 260, 269, 342, 377)
```js
fetch('/api/v1/settings')   // vs useWebSocket.js: API_BASE = DESKTOP ? DESKTOP.backendBase : ''
```
**Por qué importa:** en el Electron empaquetado la página se sirve desde el mini-servidor estático de
`main.js` (puerto aleatorio, sin proxy). Un `fetch('/api/v1/…')` resuelve contra ese origen y da 404 →
cada sección cae en "backend no disponible". **Ajustes, Atajos, Skills y el selector de voces no funcionan
en la app de escritorio** (solo en el navegador vía proxy Vite). Causa raíz: el patrón fetch está copiado
10 veces sin helper, así que el `API_BASE` que sí se puso en `useWebSocket.js` nunca se propagó.
**Fix (S):** `src/lib/api.js` con `API_BASE` + `apiGet/apiPost/apiDelete`; reemplazar las 10 llamadas.

### C6 · `npm test` escribe en tu memoria REAL y puede llamar a Ollama en vivo
`hannah-backend/tests/unit/conversationManager.test.js:26`
**Por qué importa:** `addTurn` persiste en SQLite real (`memoryStore` abre `data/memory.db` con ruta
hardcodeada, sin override para tests). Cada `npm test` inserta filas "turno N" en tu memoria de largo
plazo; con `MEMORY_RECALL` on por defecto dispara embeddings a Ollama, y al superar el umbral de resumen
**reescribe tu resumen persistente** plegando basura de test. El test pasa, pero **corrompe datos reales**.
**Fix (S):** ruta de DB inyectable (`MEMORY_DB_PATH=':memory:'` en tests) + `MEMORY_RECALL=false` en el setup.

---

## 🟡 Medios (agrupados por tema)

### Seguridad / robustez
- **DANGER es una blocklist evadible** (`tools.js:17`). Es el único gate entre el LLM y comandos destructivos
  con `systemControl=true`, y se salta trivial: `\brm\s+\S` no matchea `ls | xargs rm` ni `find . -delete`,
  `shred`, `truncate -s0`, `> archivo`, `: > f`, ni `base64|sh`/`eval`. **Fix (M):** o confirmación para TODO
  `run_command`, o dejar explícito que DANGER es best-effort (no una barrera).
- **`{arg}` de skills se interpola crudo al shell** (`skills.js:139`) → inyección con `;`/`$()`/pipes. Gated
  por `systemControl`, pero al activarlo + inyección = RCE. **Fix (M):** `execFile`/shell-quote, o tratar
  `run` con `{arg}` siempre como destructivo (confirmar).
- **SSRF en `fetch_url`/`web_search`** (`tools.js:72`): alcanzan `127.0.0.1:11434` (Ollama), `:8005` (motion),
  la LAN y metadata cloud (169.254.169.254). Una web leída antes puede hacer que Hannah lea sus endpoints
  internos. **Fix (M):** rechazar loopback/privadas/link-local antes del fetch.
- **WS sin `maxPayload` ni validación de tipo** (`websocket.js:14`): el cap de 5MB solo cubre binario; `data.frame`
  y `data.text` no se validan. **Fix (S).**
- **Electron `webSecurity:false` + `no-sandbox`** (`main.js:48`): riesgo aceptado, pero **documentarlo**.

### Duplicación (consolidar)
- **Capa determinista copiada** entre `processVoiceTurn` y `processUserTextTurn` (`orchestrator.js:161` vs 231):
  ~14 líneas casi idénticas + el string mágico *"(Responde al usuario con este resultado real…)"* dos veces.
  **Fix (S):** helper `runDeterministicLayer(text, …)`.
- **Lista de tags de acción en 2 regex a mano** (`llm.js:113` `ACTION_RE` vs `orchestrator.js:74` strip): si
  agregás un tag y olvidás el strip, **el TTS lo lee en voz alta**. **Fix (S):** derivar ambos de `Object.keys(ACTION_TOOL)`.
- **Gate DANGER→confirm duplicado** entre `run_command` (`tools.js:162`) y skills `terminal` (`skills.js:159`).
  Es seguridad: si divergen, una vía confirma distinto. **Fix (S):** `confirmIfDangerous(cmd, ctx)`.
- **Persistencia JSON duplicada** entre `settings.js` y `shortcuts.js` (`persist/load` idénticos) + `DATA_DIR`
  calculado en 4 módulos. **Fix (S):** `state/dataDir.js` + `jsonFile(name)`.
- **10 `catch → res.status(500)` idénticos** en `api/*.js` pese a haber un error-middleware global en
  `server.js:54` que hace lo mismo (nunca se alcanza). **Fix (S):** wrapper `handler(slug, fn)`.
- **Recall vectorial duplicado** entre `recallContext` (`llm.js:21`) y la tool `recall_memory` (`tools.js:32`),
  **con umbrales divergentes** (0.55 vs 0.5, K config vs 3). **Fix (S):** `recallTopK()` en `embeddings.js`.
- **backend `windowControl.js` ↔ `hannah-desktop/main.js`**: parseo de specs de movimiento y gaze (K=1.4,
  eyeY=0.32, COMPACT 400×620) copiados y **ya divergidos**. **Fix (M):** el backend manda el spec resuelto.
- **Avatares:** `VrmAvatar` y `SmplxAvatar` copian el cálculo de frame y el decode axis-angle→quaternion
  (`VrmAvatar.jsx:242` vs `SmplxAvatar.jsx:66`). **Fix (S):** `lib/motionUtils.js`.
- **Cliente OpenAI memoizado** repetido en `llm.js:33` y `vlm.js:8` (vlm no invalida por apiKey). **Fix (S).**
- **`preload_cuda_libs()` copiada** char-a-char entre `asr/main.py` y `tts/main.py`. **Fix (S):** `sidecar/common.py`.
- Menores del mismo tipo: `sh` en hyprland/x11, envelope de motion (lab/emage), strip HTML en fetch_url/web_search,
  `ensureHttps` en 2 tools, base64→bytes en useWebSocket, `CLOSE_ALIAS`, botones del HUD que ignoran `IconBtn`.

### Código muerto / sobreingeniería
- **`avatarMode` es estado zombie:** `setAvatarMode` no tiene ningún llamador; vale `'vrm'` para siempre. Deja
  muertos `Avatar.jsx` (113 líneas), `SmplxAvatar.jsx` (124) y **un `useGLTF.preload('/smplx_avatar.glb')` de
  19 MB que se baja en CADA arranque del overlay** (`SmplxAvatar.jsx:123`). **Fix (M):** borrar ambos + el
  preload + `VISEME_MAP` + `avatarMode` del store.
- **`toolSchemas()` es código muerto** del function-calling viejo (`tools.js:323`): `llm.js` la importa pero
  nunca la llama → **`config.tools.names` y la env `TOOLS` no filtran nada** (todas las tools son alcanzables
  por tags). **Fix (S):** borrar.
- **`cmdAllowlist`** (`config.js:146`) no tiene consumidor y su comentario *"con allowlist"* **es falso** — con
  `systemControl=true` corre cualquier comando. Config que desinforma sobre el riesgo real. **Fix (S):** borrar.
- **`skills.trustModel`** (`config.js:157`): editable y persistido desde el panel ⚙, pero **ningún código lo
  lee** (la capa determinista corre incondicional). UI que le miente al usuario. **Fix (S):** borrar o implementar.
- **`recall_memory` / `[RECALL:]`**: la tool existe pero ningún prompt la enseña y el propio config dice que se
  omite. Duplica `recallContext`. **Fix (S):** borrar la tool y `RECALL` de las regex.
- **Restos de Tauri:** `const isTauri` en `App.jsx:11` (muerto) + `@tauri-apps/api`/`cli` en devDeps sin
  `src-tauri/`. **Fix (S):** borrar.
- **`motion` config a medio migrar** (`config.js:118`): un solo `sidecarUrl` para dos providers incompatibles;
  el `.env.example` fija `:8004` (EMAGE) con el default provider `lab` (:8005) → **el co-speech falla en
  silencio** con el setup documentado. **Fix (S):** URLs separadas por provider.
- Menores: `getReference()` sin consumidor, `motion.js` `action`/`intensity` que nadie pasa, `pushFrame` pass-through
  de `frameStore`, doble wrapper `analyzeScene/analyzeFrame`, estado muerto en el store (`lastDetection`, `sessionId`).

### React / performance
- **`HUD.jsx:76` y `App.jsx:48` se suscriben al store SIN selector.** Zustand notifica cualquier cambio, y
  durante el habla `setVisemes` dispara varias veces/seg + `overlayGaze` a ~12 Hz + `addLog` por evento →
  **HUD y todo el árbol (Scene/Canvas incluido) re-renderizan 20+ veces/seg**. **Fix (S):** selectores atómicos
  (`useHannahStore(s => s.emotion)`). Es el fix de perf de mayor impacto. (Además `HUD` destructura `logs` que no usa.)
- **Race en `connect()`** (`useWebSocket.js:259`): tras el `await` del fetch no chequea `unmountedRef` → con
  StrictMode crea un WebSocket huérfano que queda abierto para siempre y puede reconectar solo. **Fix (S).**
- **Timer de reset de visema (120ms) no se registra** en `visemeSchedule` (`useWebSocket.js:64`): sobrevive al
  barge-in (pisa el primer visema de la frase siguiente) y el array de ids nunca se vacía. **Fix (S).**
- **`useWebSocket.js` (332 líneas) mezcla 5 responsabilidades** no-React (transporte, motor de audio, scheduler
  de visemas, decode de motion, router). **Fix (M):** extraer `lib/audioPlayer.js` + `lib/wsClient.js`.
- Menores: `useVision` no limpia interval/cámara al desmontar (crea un canvas 640×480 cada 2s); `onGaze` IPC
  sin cleanup (doble registro en StrictMode); `Avatar.jsx` reconstruye Sets en cada frame; `GAZE_ON` se envía dos veces.

### Correctness (bugs sutiles)
- **`handleOpenIntent`/`handleCloseIntent` (async) se llaman sin `await` ni `.catch`** (`orchestrator.js:165`,
  235). Un throw = `unhandledRejection` → **tumba el proceso** (viola "nunca crashear"). Igual `moveWindow()`
  en 66/164/234. Y el boolean que devuelven se ignora → el modelo puede re-abrir la app vía `[OPEN:]`. **Fix (S).**
- **Con tools activas se pierde el pipelining por oración** (`llm.js:129`): la respuesta entra entera como UN
  segmento → una sola llamada TTS gigante, time-to-first-audio = generación completa. Rompe el objetivo <500ms
  y "stream en cada etapa" en cada turno. **Fix (S):** partir por oración también en el camino sin acciones.
- **`recentUserMove` Map crece sin límite** por sessionId (`orchestrator.js:49`); igual `_session_prefix` en
  `motion-lab/serve/main.py:39` (retiene tensores CUDA por sesión para siempre). **Fix (S):** TTL/LRU.
- **`/text` sin handler de `error` en el audioStream** (`router.js:53`): si el stream falla la request queda
  colgada para siempre. **Fix (S).**

### Python (sidecars + motion-lab)
- **Endpoints `async def` con inferencia síncrona** bloquean el event loop en los 4 sidecars (`/health` no
  responde durante cada inferencia; requests concurrentes se serializan). **Fix (S):** declararlos `def` (FastAPI
  los manda al threadpool) o `run_in_executor`.
- **Vision no valida la entrada** (`vision/main.py:21`): base64/imagen corruptos → 500 crudo en vez de 400 (los
  otros sidecars sí devuelven 400). **Fix (S).** Además: sin `/health`, `print()` en vez de logging, uploads sin
  límite de tamaño.
- **`train_vae.py`/`train_flow.py` duplican ~60 líneas** de andamiaje ya divergido (umbral NaN 1e3 vs 1e4). **Fix (M).**
- Menores: T5 y modelos que se cargan en el primer request (no en startup); `requirements.txt` con pins mixtos
  (`ultralytics`/`pillow` sin pin); resume de checkpoint que no restaura el optimizador.

### Config / contratos / docs
- **`process.env` fuera de `config.js`** en `terminal.js:15` (SHELL/COMSPEC), `hyprland.js:16`, `x11.js:10`
  (viola la regla). **Fix (S).**
- **Docs desactualizadas:** README/CLAUDE.md/.env.example dicen cosas que ya no son ciertas (Hannah "habla
  español" vs protocol en inglés; sección motion como "EMAGE :8004"; tools "OFF por defecto" vs `.env` con
  `TOOLS_ENABLED=true`). *(El auditor de consistencia cayó por el límite de sesión — esto es de otros auditores;
  conviene una pasada dedicada.)*

### Tests / tooling
- **0 ESLint** en los 3 repos JS (sin config, sin script, sin devDep). Atraparía gratis los `no-unused-vars`,
  `react-hooks/exhaustive-deps` y fire-and-forget de arriba. **Fix (S).**
- **La capa regex-heavy no tiene un solo test:** `parseMoveIntent`, `resolveDataAction`/`handleOpen`/`handleClose`,
  `parseFrontmatter`/`sshArg`/`resolveSkillPhrase`, el strip de tags del orchestrator, y **el guard `DANGER`**
  (lo único que decide si se pide confirmación antes de un `rm`). Son funciones puras: el test más barato y de
  más valor del repo. **Fix (S–M):** suites table-driven `string → esperado`.
- **`llm.test.js`** parte de una premisa obsoleta (el cliente OpenAI ya no se instancia al importar). Revisar.
- **Deps declaradas sin usar:** `@anthropic-ai/sdk`, `supertest`, `@tauri-apps/*`. **Fix (S).**

---

## ⚪ Menores (45) — resumen
Casi todos son **duplicación chica** (helpers copiados: `sh`, base64→bytes, `ensureHttps`, `stripHtml`, envelope
de motion, formato `[Salida real de…]`), **magic numbers repetidos** (el suelo `-1.6` en 4 archivos; paleta/tipografía
inline sin módulo de tokens), **pass-throughs muertos** (`visionLoop` re-exporta `frameStore`), y **pulido de
robustez** (`get_weather` sin timeout, `console.error` en vez de logger, el launcher con pasos frágiles). Ninguno
urgente; se barren de a poco o junto con el refactor del tema que los contiene. Lista completa en el journal del
workflow.

---

## Cómo seguimos (propuesta de tandas)
1. **Seguridad (antes de exponer/publicar):** C1–C4 + gate del terminal + SSRF. ~1 sesión, casi todo S.
2. **Barrido de código muerto:** avatares+preload 19MB, toolSchemas/names, cmdAllowlist, trustModel, recall_memory,
   Tauri, estado zombie del store. Adelgaza ~500 líneas + 19MB. Bajo riesgo.
3. **React perf + Electron:** selectores del store, `lib/api.js` (arregla panels), race de connect, timers de visema.
4. **Dedup estructural:** `dataDir`/`jsonFile`, wrapper de errores API, tags de acción de una sola fuente,
   `motionUtils`, capa determinista del orchestrator, `sidecar/common.py`.
5. **Red de seguridad:** ESLint en los 3 repos + tests table-driven de la capa regex/DANGER + fix del test que
   corrompe memoria.
6. **Docs:** pasada de consistencia (README/CLAUDE.md/.env.example).

*Decime qué tanda arranco (o hallazgos sueltos) y lo aplico en commits separados como pedrochgdev.*
