# Setup de Hannah en una máquina nueva

Guía para dejar Hannah corriendo desde cero. Pensada para **Arch / CachyOS** (los comandos de
paquetes son `pacman`; en otras distros cambiá solo esa parte).

> **Lo importante primero:** clonar los repos **no alcanza**. Los pesos de los modelos (voz,
> gestos) están gitignored porque pesan ~700 MB, así que hay que conseguirlos aparte. Este
> documento marca cuáles son obligatorios y qué se rompe si falta cada uno.

---

## 0. Estructura esperada

Todo cuelga de una carpeta de trabajo (el "meta-repo"). Los nombres de las carpetas importan:
el launcher y los venvs los asumen.

```
Hannah-Motion/            ← este repo (launcher + docs)
├── hannah                ← launcher bash (Super+H)
├── hannah-backend/       ← repo: backend
├── hannah-frontend/      ← repo: frontend
├── hannah-motion-lab/    ← repo: modelo de gestos (opcional pero recomendado)
├── hannah-desktop/       ← repo: app Electron (opcional)
└── .venv/                ← venv del sidecar EMAGE (solo si usás MOTION_PROVIDER=emage)
```

```bash
git clone <url-de-este-repo> Hannah-Motion && cd Hannah-Motion
git clone https://github.com/Hannah-Motion-Lab/backend.git      hannah-backend
git clone https://github.com/Hannah-Motion-Lab/frontend.git     hannah-frontend
git clone https://github.com/Hannah-Motion-Lab/motion-model.git hannah-motion-lab
```

---

## 1. Requisitos del sistema

```bash
sudo pacman -S nodejs npm python python-pip git curl
# opcional pero recomendado (crea los venvs mucho más rápido):
sudo pacman -S uv
```

- **Node 20+** y **Python 3.12+**.
- **GPU NVIDIA**: instalá los drivers + CUDA. Todo el stack cabe en **≤16 GB de VRAM**.
- **GPU AMD / sin GPU**: funciona igual, pero los sidecars caen a **CPU** (más lento, sobre todo
  el TTS). El sidecar EMAGE (opcional) sí necesita CUDA.

---

## 2. Ollama (el cerebro)

```bash
sudo pacman -S ollama          # o: curl -fsSL https://ollama.com/install.sh | sh
systemctl --user enable --now ollama     # o simplemente: ollama serve

ollama pull qwen2.5:7b         # LLM principal (~5 GB) — el que mejor emite las acciones
ollama pull nomic-embed-text   # embeddings para la memoria (~275 MB)
ollama pull moondream          # visión: describe lo que ve la cámara (~1.7 GB)
```

Verificá: `curl -s localhost:11434/api/tags` debe listar los tres.

---

## 3. Backend

```bash
cd hannah-backend
npm install
cp .env.example .env
```

Editá `.env` — lo mínimo:

```bash
LLM_MODEL=qwen2.5:7b       # el ejemplo trae llama3.1:8b; qwen2.5 anda mejor con acciones
TOOLS_ENABLED=true         # que Hannah pueda actuar (internet, abrir/cerrar, comandos)
TOOLS_SYSTEM_CONTROL=true  # TERMINAL REAL — leé la advertencia de seguridad más abajo
```

> **`HOST` queda en `127.0.0.1`** (recomendado). El acceso desde el celular funciona igual:
> entra por Vite (`:5173`), que hace de proxy. No lo pongas en `0.0.0.0` salvo que sepas
> lo que hacés: expondría la terminal, tus API keys y tu memoria a toda la red.

### Sidecars de Python (ASR, TTS, visión)

```bash
cd hannah-backend/sidecar
uv venv .venv --python 3.12          # o: python -m venv .venv
uv pip install -r requirements.txt   # o: .venv/bin/pip install -r requirements.txt
```

### Pesos de la voz (OBLIGATORIO — sin esto Hannah no habla)

No están en git. Bajá los del release **v1.0** de `kokoro-onnx` a `hannah-backend/sidecar/tts/`:

```bash
cd hannah-backend/sidecar/tts
# kokoro-v1.0.onnx (~311 MB) y voices-v1.0.bin (~27 MB)
# release: https://github.com/thewh1teagle/kokoro-onnx/releases  (model-files v1.0)
curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
```

Deben quedar exactamente con esos nombres, al lado de `main.py`. (Si el release cambió de
lugar, buscá "kokoro-onnx model files v1.0" — la versión del paquete es `kokoro-onnx==0.4.7`.)

### YOLO (opcional)

Solo si vas a usar `VISION_PROVIDER=yolo` en vez del VLM por defecto: poné `yolov8n.pt` en
`hannah-backend/sidecar/vision/` (lo descarga `ultralytics` la primera vez que se usa).

---

## 4. Frontend

```bash
cd hannah-frontend
npm install --legacy-peer-deps   # el flag NO es opcional (vite 5 vs plugin-basic-ssl)
```

El avatar (`public/avatar.glb`) y los clips de gestos ya vienen en el repo.

---

## 5. Modelo de gestos (para que se mueva al hablar)

```bash
cd hannah-motion-lab
uv venv .venv --python 3.12
uv pip install -r requirements.txt
```

**Los pesos entrenados NO están en git** (`runs/` está gitignored). Sin ellos el sidecar de
motion no levanta y Hannah habla **sin gestos co-speech** (el resto funciona normal).

Necesitás estos dos archivos, copiados de la máquina donde se entrenó:

```
hannah-motion-lab/runs/vae/latest.pt     (~175 MB)
hannah-motion-lab/runs/flow/latest.pt    (~214 MB)
```

(Se pueden re-entrenar con los scripts de `src/motionlab/train/`, pero lleva horas de GPU.)
Las rutas se pueden cambiar con las env `VAE_CKPT` / `FLOW_CKPT`.

---

## 6. Arrancar

**Opción A — todo de una (Linux):**

```bash
./hannah          # levanta Ollama, sidecars, backend, Vite y abre el overlay
```

Conviene atarlo a un atajo de teclado (el autor usa **Super+H**). En Hyprland:

```
bind = SUPER, H, exec, /ruta/a/Hannah-Motion/hannah
```

**Opción B — a mano (para ver los logs):**

```bash
cd hannah-backend && npm run sidecar:tts     # :8002  (voz — imprescindible)
cd hannah-backend && npm run sidecar:asr     # :8001  (escuchar)
cd hannah-motion-lab && .venv/bin/python -m uvicorn serve.main:app --port 8005   # gestos
cd hannah-backend && npm run dev             # :3001  backend
cd hannah-frontend && npm run dev            # :5173  interfaz  → abrir en el navegador
```

**Desde el celular / otra compu de la red:** entrá a `https://<ip-de-la-pc>:5173` (aceptá el
certificado autofirmado). Vite proxea al backend, así que funciona todo, terminal incluida.

---

## 7. Verificar que quedó bien

```bash
curl -s localhost:3001/api/v1/health          # backend
curl -s localhost:8002/health                 # TTS (dice si usa CUDA o CPU)
curl -s localhost:8005/health                 # gestos
curl -s localhost:11434/api/tags              # modelos de Ollama
```

Después, en la interfaz: decile algo. Deberías tener **respuesta escrita + voz + movimiento**.

| Si falta… | Síntoma |
|---|---|
| pesos de Kokoro | responde por texto pero **no se oye nada** |
| `runs/*.pt` del motion-lab | habla pero **no gesticula** al hablar |
| Ollama / el modelo | **no responde nada** |
| sidecar ASR | no te entiende por voz (el texto sí funciona) |

---

## 8. El overlay flotante en tu escritorio

**Empezá por acá:**

```bash
./hannah doctor      # dice si tu entorno soporta el overlay, y qué falta
```

Hannah puede flotar **encima de todo** en cualquier escritorio, pero la vía cambia:

| Escritorio / sesión | Cómo flota | Qué necesitás |
|---|---|---|
| **Hyprland** | nativo (`hyprctl`) | nada |
| **KDE Plasma** (Wayland o X11) | KWin | `kdotool` (recomendado) o `wmctrl` |
| **GNOME, XFCE, Cinnamon, MATE, i3** (X11) | EWMH estándar | `wmctrl` |
| **GNOME/KDE en Wayland** | vía **XWayland** | usar la **app de escritorio** (fuerza XWayland) |
| **Windows / macOS** | nativo de Electron | nada |

> **Por qué XWayland:** en Wayland *nativo* el protocolo **prohíbe** que una app se ponga
> encima o se mueva sola (es decisión de diseño de Wayland, no un bug). Por eso la app de
> escritorio arranca forzada a XWayland (`ozone-platform=x11`), donde la ventana es X11 real
> y todos los compositores respetan el "siempre encima". Si querés experimentar con Wayland
> nativo: `HANNAH_OZONE=wayland` — pero perdés flotar y mover entre monitores.

**La forma más portable** es la app de escritorio, que ya trae todo resuelto:

```bash
cd hannah-frontend && npm run build          # genera el dist que empaqueta la app
cd ../hannah-desktop && npm install && npm start
```

Instalá además `wmctrl` (o `kdotool` en KDE) para que Hannah pueda **moverse por voz**
("andá al centro", "pasate a la otra pantalla"):

```bash
sudo pacman -S wmctrl        # Arch/CachyOS
sudo apt install wmctrl      # Debian/Ubuntu
sudo dnf install wmctrl      # Fedora
```

**Si tu escritorio no aparece flotando:** corré `./hannah doctor`, que te dice exactamente
qué falta. Y si estás en GNOME Wayland y aun con la app no flota, reportalo con la salida de
`wmctrl -l` y `xprop -name Hannah _NET_WM_STATE` (ver checklist abajo).

### Checklist para verificar en tu máquina (si no es Hyprland)

```bash
./hannah doctor                              # 1. veredicto del entorno
wmctrl -l | grep -i hannah                   # 2. ¿la ventana es visible para X11?
xprop -name Hannah _NET_WM_STATE             # 3. ¿aparece _NET_WM_STATE_ABOVE?
```
Abrí otra ventana maximizada encima: Hannah debería quedar visible por delante.

## 9. Seguridad — leé esto antes de activar la terminal

`TOOLS_SYSTEM_CONTROL=true` le da a Hannah una **shell real** en tu máquina (la misma que usa
el panel ⌨). **No hay lista blanca de comandos**: puede ejecutar cualquier cosa. La única red
es que los comandos destructivos (`rm`, `dd`, `mkfs`, `shutdown`, `git --force`…) **te piden
confirmación** en un modal — es *best-effort*, no una barrera de seguridad.

Si no lo necesitás, dejalo en `false`: Hannah sigue conversando, viendo por la cámara,
buscando en internet y abriendo páginas.

Tampoco compartas tu `hannah-backend/.env` ni `hannah-backend/data/` (ahí viven las API keys y
tu memoria de conversaciones); ya están gitignored.

---

## 10. Problemas comunes

**`npm install` falla en el frontend** (`ERESOLVE`) → usá `--legacy-peer-deps`. Es un conflicto
conocido entre vite 5 y `@vitejs/plugin-basic-ssl`.

**Super+H no hace nada** → suele ser un Vite levantado a mano en HTTPS ocupando el `:5173`; el
overlay lo necesita en HTTP. Cerralo (`pkill -f 'bin/vite'`) y volvé a lanzar; el launcher te
avisa si detecta ese caso. Revisá también `.hannah-launch.log`.

**No hay voz** → mirá que el sidecar TTS esté arriba (`curl localhost:8002/health`) y que los
dos archivos de Kokoro estén en `sidecar/tts/` con el nombre exacto.

**"No responde nada" de golpe** → mirá que Ollama esté corriendo y que el modelo de `.env`
exista (`ollama list`).

**El micrófono no funciona en la LAN** → el navegador exige HTTPS fuera de localhost; usá
`https://<ip>:5173` (no `http://`) y aceptá el certificado.

**La app de escritorio no arranca: `Error: spawn .../electron/dist/electron ENOENT`** (fijate
si la ruta del error termina en `\n`) → el archivo `node_modules/electron/path.txt` quedó con
un salto de línea y Electron lo lee sin recortarlo. Pasa cuando el binario se instaló a mano
(postinstall bloqueado). Se arregla con:
```bash
cd hannah-desktop && printf 'electron' > node_modules/electron/path.txt
```
Si además falta el binario (`dist/electron` no existe), reinstalá permitiendo el postinstall:
`npm rebuild electron` o `npm install electron --force`.

**Todo va lento** → revisá si los sidecars están en CPU: `curl -s localhost:8002/health` dice
el provider. Sin CUDA, el TTS es el cuello de botella.
