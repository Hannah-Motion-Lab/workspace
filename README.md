# Hannah — avatar IA interactivo en tiempo real

Hannah es una **compañera IA** que ves y oyes: hablas (o le muestras la cámara) y un
avatar 3D responde con voz, lip-sync, emoción y **gestos co-speech**, viviendo como un
**overlay flotante** en tu escritorio. Todo el stack por defecto es **local** (Ollama,
Whisper, Kokoro, YOLO/VLM). Además puede **usar internet** y **una terminal real**.

## Componentes (repos)

| Dir | Qué es | Lenguaje |
|-----|--------|----------|
| `hannah-backend/` | Gateway WS + REST: orquesta ASR→LLM→TTS→lip-sync + sidecars Python (Whisper, Kokoro, YOLO/VLM). Tools (internet, terminal), memoria, control de ventana. | Node (ESM) |
| `hannah-frontend/` | Cliente React + three.js: avatar VRoid/VRM, mic, cámara, HUD, panel de terminal. | React/Vite |
| `hannah-motion-lab/` | Modelo texto→movimiento (gestos) servido en :8005. | Python |
| `hannah-desktop/` | **App de escritorio Electron** (overlay universal Win/Mac/Linux). | Electron |
| `hannah` | **Launcher**: levanta todo el stack y abre el overlay (por defecto, la app). | Bash |

## Arquitectura en 30s

- **App web universal**: backend (Node) + frontend (web) corren en cualquier OS/navegador.
- **Capa overlay** (flotar encima, mover entre pantallas, mirada que sigue el cursor):
  dos formas de correrla —
  1. **Modo navegador** (`hannah` launcher): abre el frontend en un navegador en modo-app
     y lo coloca con el **adaptador** del entorno (Hyprland vía `hyprctl`, X11 vía
     `xdotool`/`wmctrl`). Ligero, sin instalar nada extra. Linux.
  2. **App Electron** (`hannah-desktop`): Chromium, overlay con APIs cross-platform
     (`setAlwaysOnTop`, `setBounds`, `getCursorScreenPoint`, `getAllDisplays`). **Win/Mac/Linux**.

## Puertos y red

| Servicio | Puerto | |
|---|---|---|
| Backend (API + WS) | 3001 | escucha en **127.0.0.1** (env `HOST`) |
| Frontend (Vite) | 5173 | escucha en `0.0.0.0` — por acá entra el celular |
| ASR · TTS · Visión | 8001 · 8002 · 8003 | sidecars locales |
| Motion (lab, default) | 8005 | `hannah-motion-lab` · EMAGE en 8004 (fallback) |
| Ollama | 11434 | LLM + embeddings |

> **Acceso desde el celular/otra compu:** entrás a `https://<ip-de-tu-pc>:5173` y Vite hace de
> proxy hacia el backend local. El backend **no** queda expuesto a la red (ni la terminal, ni
> tus API keys, ni la memoria). Solo poné `HOST=0.0.0.0` si sabés lo que hacés.

**Idioma:** hoy Hannah **habla inglés** (el protocolo del LLM lo fuerza, en `config.js`); el ASR
detecta idioma solo, así que le podés hablar en español. Se cambia editando `llm.protocol` y la
voz (`ELEVENLABS_VOICE_ID`: `af_*`/`am_*` inglés, `ef_*`/`em_*` español…).

**Memoria:** además del historial de sesión, guarda memoria de largo plazo en SQLite
(`hannah-backend/data/memory.db`) con resumen rodante y recall vectorial.

## Requisitos

> **Objetivo de VRAM: ≤16GB** — todo el stack (LLM + embeddings + TTS + ASR + visión +
> motion) cabe en 16GB o menos. Por eso el LLM es un **7B** y los **tools usan un
> protocolo de acciones por tags** (fiable en modelos chicos), no function-calling.

- **Ollama** con `qwen2.5:7b` (chat + tools, ~5GB) y `nomic-embed-text` (memoria);
  `llama3.1:8b` sirve si no usas tools.
- Python 3.12 + venvs para los sidecars (detalle en `hannah-backend/README.md`).
- Node 20+. Para la app Electron: nada extra (trae Chromium).
- Overlay en Linux: `hyprctl` (Hyprland) **o** `xdotool`+`wmctrl` (X11).

## Correr

```bash
# 1) instalar (una vez)
cd hannah-backend  && npm install && cp .env.example .env
cd ../hannah-frontend && npm install --legacy-peer-deps   # ojo: sin el flag falla (vite 5 vs plugin-basic-ssl)

# 2) levanta todo (Ollama, sidecars, backend, Vite) y abre el overlay:
./hannah                       # abre la app Electron; si ya está abierta, la enfoca
./hannah stop                  # apaga TODO y libera la VRAM (modelos de Ollama incluidos)
./hannah doctor                # diagnostica si el overlay va a flotar acá, y qué falta
HANNAH_MODE=browser ./hannah   # alternativa liviana: el frontend en un navegador

# 2') o la app de escritorio sola (Win/Mac/Linux), con el backend ya corriendo:
cd hannah-desktop && npm install && npm run start:dev   # usa el Vite de :5173
cd hannah-frontend && npm run build && cd ../hannah-desktop && npm start   # sin Vite, desde dist/
```

> **Cerrar la ventana apaga todo.** Los sidecars y los modelos cargados retienen VRAM mientras
> viven (~14GB en una sesión típica), así que al cerrar el overlay lanzado por `./hannah` se
> apaga el stack entero y se descargan los modelos de Ollama. Si preferís conservarlos calientes:
> `./hannah stop --keep-ollama`, o `--dry-run` para ver qué se apagaría sin tocar nada.

## Documentación por repo

| Dónde | Qué encontrás |
|---|---|
| `hannah-backend/README.md` | Contratos WS y REST, el recorrido de un turno, la capa determinista de acciones, configuración y decisiones de diseño |
| `hannah-desktop/README.md` | Por qué XWayland, por qué los flags van en argv, la geometría vía compositor y el comportamiento de la ventana |
| `hannah-frontend/README.md` | Avatar VRM, retarget desde geometría, estado y captura de audio |
| `SETUP.md` | Levantar todo en una máquina nueva, paso a paso |
| `SKILLS.md` | Enseñarle capacidades sin tocar código |

## Tools (internet + terminal)

Están **OFF por defecto**. Se activan en tu `.env` (no como variables sueltas):

```bash
# hannah-backend/.env
TOOLS_ENABLED=true          # acciones (internet, abrir/cerrar, comandos)
TOOLS_SYSTEM_CONTROL=true   # master flag de la TERMINAL real (pty) — implica acceso shell
```

- **Internet**: `web_search` (DuckDuckGo) y `fetch_url` (leer webs).
- **Terminal**: shell persistente real (`node-pty`, soporta ssh/interactivos) + panel `⌨`
  en la UI. **No hay allowlist de comandos**: con el flag activo corre cualquier cosa; la
  única red es la **confirmación para destructivos** (`rm`, `dd`, `mkfs`, `shutdown`,
  `git --force`…, regex `DANGER`, best-effort). `TOOLS_SYSTEM_CONTROL` gatea por igual
  `run_command`, las skills de tipo `terminal` y el panel.
- **Skills y referencia**: podés enseñarle capacidades sin tocar código —
  `hannah-backend/skills/<nombre>/SKILL.md` (acción `run`/`terminal`/`open`/`search`, con
  variantes por SO) y `reference/*.md` (cheat-sheets que guían al modelo). Ver `SKILLS.md`.

## Distribuir (builds por OS)

```bash
cd hannah-desktop
npm run build:linux   # .AppImage / .deb   (probado: Hannah-*.AppImage corre self-contained)
npm run build:win     # .exe  — requiere Windows o Wine (NO sale desde Linux pelado)
npm run build:mac     # .dmg  — requiere macOS (imposible desde Linux)
```
> Antes de empaquetar: `cd hannah-frontend && npm run build` (el Electron carga ese `dist/`).
> Para los tres SO a la vez, lo práctico es CI (GitHub Actions con runners nativos).
> La app Electron es el **overlay**; sigue necesitando el **backend + Ollama + sidecars**
> corriendo (local). Empaquetar el backend como servicio es trabajo futuro.

## Matriz de plataformas (overlay)

Corré **`./hannah doctor`**: te dice si tu entorno soporta el overlay y qué falta.

| Escritorio | Cómo flota | Requisito |
|-----------|------------|-----------|
| Hyprland | nativo (`hyprctl`) | — |
| KDE Plasma (Wayland/X11) | KWin | `kdotool` o `wmctrl` |
| GNOME · XFCE · Cinnamon · MATE · i3 (X11) | EWMH | `wmctrl` |
| GNOME/KDE en Wayland | vía XWayland | usar la app de escritorio |
| Windows · macOS | nativo de Electron | — |

> En **Wayland nativo** el protocolo prohíbe que una app se ponga encima o se mueva sola (es
> su diseño). Por eso la app de escritorio fuerza **XWayland**, y así el mismo código flota en
> todos los escritorios. Detalle en `SETUP.md`.

## Notas

- **No retargeting** de motion a rigs foráneos (lección "zombie pose"): el avatar VRoid
  usa un retarget calculado desde geometría. Ver CLAUDE.md.
- Privacidad: audio en memoria, nunca a disco; no se loguea contenido del usuario.
- Licencias de assets (SMPL-X no-comercial, Mixamo Adobe) — quedan gitignorados.
