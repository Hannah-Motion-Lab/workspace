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
| `hannah` | **Launcher** (modo navegador): levanta todo y abre el overlay en Linux. | Bash |

## Arquitectura en 30s

- **App web universal**: backend (Node) + frontend (web) corren en cualquier OS/navegador.
- **Capa overlay** (flotar encima, mover entre pantallas, mirada que sigue el cursor):
  dos formas de correrla —
  1. **Modo navegador** (`hannah` launcher): abre el frontend en un navegador en modo-app
     y lo coloca con el **adaptador** del entorno (Hyprland vía `hyprctl`, X11 vía
     `xdotool`/`wmctrl`). Ligero, sin instalar nada extra. Linux.
  2. **App Electron** (`hannah-desktop`): Chromium, overlay con APIs cross-platform
     (`setAlwaysOnTop`, `setBounds`, `getCursorScreenPoint`, `getAllDisplays`). **Win/Mac/Linux**.

## Requisitos

> **Objetivo de VRAM: ≤16GB** — todo el stack (LLM + embeddings + TTS + ASR + visión +
> motion) cabe en 16GB o menos. Por eso el LLM es un **7B** y los **tools usan un
> protocolo de acciones por tags** (fiable en modelos chicos), no function-calling.

- **Ollama** con `qwen2.5:7b` (chat + tools, ~5GB) y `nomic-embed-text` (memoria);
  `llama3.1:8b` sirve si no usas tools.
- Python 3.12 + venvs para los sidecars (ver `hannah-backend/README.md` y CLAUDE.md).
- Node 20+. Para la app Electron: nada extra (trae Chromium).
- Overlay en Linux: `hyprctl` (Hyprland) **o** `xdotool`+`wmctrl` (X11).

## Correr

```bash
# 1) instalar (una vez)
cd hannah-backend && npm install
cd ../hannah-frontend && npm install

# 2) modo navegador (Linux) — levanta todo y abre el overlay:
./hannah

# 2') o la app de escritorio (Win/Mac/Linux):
cd hannah-frontend && npm run build        # genera dist/
cd ../hannah-desktop && npm install && npm start
```

## Tools (internet + terminal)

Están **OFF por defecto** (un modelo flojo con tools ensucia el chat). Actívalos:

```bash
TOOLS_ENABLED=true TOOLS_SYSTEM_CONTROL=true LLM_MODEL=qwen2.5:7b   # (o pon qwen2.5 en el ⚙)
```

- **Internet**: `web_search` (DuckDuckGo) y `fetch_url` (leer webs).
- **Terminal**: shell persistente real (`node-pty`, soporta ssh/interactivos) + panel
  `⌨` en la UI. Corre libre; **solo pide confirmación para comandos destructivos**
  (`rm -rf`, `dd`, `mkfs`, `sudo rm`…). `TOOLS_SYSTEM_CONTROL` es el master flag (OFF por
  defecto).

## Distribuir (builds por OS)

```bash
cd hannah-desktop
npm run build:linux   # .AppImage / .deb   (probado: Hannah-*.AppImage corre self-contained)
npm run build:win     # .exe  (correr en Windows o CI)
npm run build:mac     # .dmg  (correr en macOS o CI)
```
> La app Electron es el **overlay**; sigue necesitando el **backend + Ollama + sidecars**
> corriendo (local). Empaquetar el backend como servicio es trabajo futuro.

## Matriz de plataformas (overlay)

| Plataforma | Modo navegador (`hannah`) | App Electron |
|-----------|---------------------------|--------------|
| Linux Hyprland (Wayland) | ✅ float+pin vía hyprctl | ✅ (necesita float+pin de Hyprland, tiling) |
| Linux X11 / XWayland | ✅ xdotool/wmctrl | ✅ always-on-top nativo |
| Linux GNOME/KDE Wayland | ⚠️ degrada a ventana | ⚠️ always-on-top limitado (usar XWayland) |
| Windows / macOS | — | ✅ always-on-top nativo |

## Notas

- **No retargeting** de motion a rigs foráneos (lección "zombie pose"): el avatar VRoid
  usa un retarget calculado desde geometría. Ver CLAUDE.md.
- Privacidad: audio en memoria, nunca a disco; no se loguea contenido del usuario.
- Licencias de assets (SMPL-X no-comercial, Mixamo Adobe) — quedan gitignorados.
