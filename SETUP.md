# Hannah setup on a new machine

Guide to get Hannah running from scratch. Written for **Arch / CachyOS** (the package commands
are `pacman`; on other distros change only that part).

> **The important bit first:** cloning the repos is **not enough**. The model weights (voice,
> gestures) are gitignored because they weigh ~700 MB, so you have to get them separately. This
> document marks which ones are mandatory and what breaks if each one is missing.

---

## 0. Expected structure

Everything lives under a single working folder (the "meta-repo"). The folder names matter: the
launcher and the venvs assume them.

```
Hannah-Motion/            ← this repo (launcher + docs)
├── hannah                ← bash launcher (Super+H)
├── hannah-backend/       ← repo: backend
├── hannah-frontend/      ← repo: frontend
├── hannah-motion-lab/    ← repo: gesture model (optional but recommended)
├── hannah-desktop/       ← repo: Electron app (optional)
└── .venv/                ← EMAGE sidecar venv (only if you use MOTION_PROVIDER=emage)
```

```bash
git clone <url-of-this-repo> Hannah-Motion && cd Hannah-Motion
git clone https://github.com/Hannah-Motion-Lab/backend.git      hannah-backend
git clone https://github.com/Hannah-Motion-Lab/frontend.git     hannah-frontend
git clone https://github.com/Hannah-Motion-Lab/motion-model.git hannah-motion-lab
```

---

## 1. System requirements

```bash
sudo pacman -S nodejs npm python python-pip git curl
# optional but recommended (creates the venvs much faster):
sudo pacman -S uv
```

- **Node 20+** and **Python 3.12+**.
- **NVIDIA GPU**: install the drivers + CUDA. The whole stack fits in **≤16 GB of VRAM**.
- **AMD GPU / no GPU**: it still works, but the sidecars fall back to **CPU** (slower, especially
  the TTS). The EMAGE sidecar (optional) does need CUDA.

---

## 2. Ollama (the brain)

```bash
sudo pacman -S ollama          # or: curl -fsSL https://ollama.com/install.sh | sh
systemctl --user enable --now ollama     # or just: ollama serve

ollama pull qwen2.5:7b         # main LLM (~5 GB) — the best at emitting the actions
ollama pull nomic-embed-text   # embeddings for the memory (~275 MB)
ollama pull moondream          # vision: describes what the camera sees (~1.7 GB)
```

Check it: `curl -s localhost:11434/api/tags` must list all three.

---

## 3. Backend

```bash
cd hannah-backend
npm install
cp .env.example .env
```

Edit `.env` — the bare minimum:

```bash
LLM_MODEL=qwen2.5:7b       # the example ships llama3.1:8b; qwen2.5 does better with actions
TOOLS_ENABLED=true         # let Hannah act (internet, open/close, commands)
TOOLS_SYSTEM_CONTROL=true  # REAL TERMINAL — read the security warning further down
```

> **`HOST` stays at `127.0.0.1`** (recommended). Access from your phone still works: it comes in
> through Vite (`:5173`), which acts as a proxy. Don't set it to `0.0.0.0` unless you know what
> you're doing: it would expose the terminal, your API keys and your memory to the whole network.

### Python sidecars (ASR, TTS, vision)

```bash
cd hannah-backend/sidecar
uv venv .venv --python 3.12          # or: python -m venv .venv
uv pip install -r requirements.txt   # or: .venv/bin/pip install -r requirements.txt
```

### Voice weights (MANDATORY — without this Hannah doesn't speak)

They are not in git. Download them from the **v1.0** release of `kokoro-onnx` into
`hannah-backend/sidecar/tts/`:

```bash
cd hannah-backend/sidecar/tts
# kokoro-v1.0.onnx (~311 MB) and voices-v1.0.bin (~27 MB)
# release: https://github.com/thewh1teagle/kokoro-onnx/releases  (model-files v1.0)
curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
```

They must end up with exactly those names, next to `main.py`. (If the release moved somewhere
else, search for "kokoro-onnx model files v1.0" — the package version is `kokoro-onnx==0.4.7`.)

### YOLO (optional)

Only if you're going to use `VISION_PROVIDER=yolo` instead of the default VLM: put `yolov8n.pt` in
`hannah-backend/sidecar/vision/` (`ultralytics` downloads it the first time it's used).

---

## 4. Frontend

```bash
cd hannah-frontend
npm install --legacy-peer-deps   # the flag is NOT optional (vite 5 vs plugin-basic-ssl)
```

The avatar (`public/avatar.glb`) and the gesture clips already ship in the repo.

---

## 5. Gesture model (so she moves while speaking)

```bash
cd hannah-motion-lab
uv venv .venv --python 3.12
uv pip install -r requirements.txt
```

**The trained weights are NOT in git** (`runs/` is gitignored). Without them the motion sidecar
doesn't start and Hannah speaks **without co-speech gestures** (everything else works normally).

You need these two files, copied from the machine where it was trained:

```
hannah-motion-lab/runs/vae/latest.pt     (~175 MB)
hannah-motion-lab/runs/flow/latest.pt    (~214 MB)
```

(They can be re-trained with the scripts in `src/motionlab/train/`, but it takes hours of GPU time.)
The paths can be changed with the `VAE_CKPT` / `FLOW_CKPT` env vars.

---

## 5b. The hands (optional): `hannah-agent`

Skip this unless you want multi-step tasks ("organize my downloads by type"). Hannah talks and
runs simple commands without it.

```bash
# 1) bun (the agent is TypeScript run by bun, not Node)
sudo pacman -S unzip && curl -fsSL https://bun.sh/install | bash     # CachyOS/Arch; Debian: apt install unzip
cd hannah-agent && bun install

# 2) the model — remote either way: READ THE PRIVACY NOTE in README.
#    Default profile: Claude Sonnet 5 (Anthropic). Key: https://console.anthropic.com
scripts/install-profile.sh                     # writes ~/.config/hannah-agent/
#    alternatives: --openrouter  GLM 5.3 Flash (Z.ai) via OpenRouter, cheaper; key at
#                               https://openrouter.ai/keys — the account needs CREDITS
#                  --local      Ollama, needs qwen3-coder:30b — does NOT fit next to the rest in 16GB

# 3) tell the backend, in hannah-backend/.env
AGENT_ENABLED=true
ANTHROPIC_API_KEY=sk-ant-...          # or OPENROUTER_API_KEY=sk-or-... with --openrouter
```

The key can also be pasted in the ⚙ panel ("Manos"), which wins over `.env`. The launcher tells the
provider from the key's prefix (`sk-ant-` / `sk-or-`) and passes it to the agent; the backend never
uses it. Then `./hannah` starts the agent on `:8006` before the backend, and `./hannah stop` shuts
it down. A read-only task like "count the files in my Downloads and name the three largest" runs
two commands and costs a few cents on Sonnet.
`./hannah doctor` tells you which of the three pieces (bun, profile, key) is missing. **Without a
key (or credits) the agent starts but every task fails at the model** — Hannah will say the task failed; she
will not pretend it worked.

## 6. Bringing it up

**Option A — everything at once (Linux):**

```bash
./hannah          # starts Ollama, sidecars, backend, Vite and opens the overlay
```

It's worth binding it to a keyboard shortcut (the author uses **Super+H**). On Hyprland:

```
bind = SUPER, H, exec, /path/to/Hannah-Motion/hannah
```

**Option B — by hand (to see the logs):**

```bash
cd hannah-backend && npm run sidecar:tts     # :8002  (voice — essential)
cd hannah-backend && npm run sidecar:asr     # :8001  (listening)
cd hannah-motion-lab && .venv/bin/python -m uvicorn serve.main:app --port 8005   # gestures
cd hannah-backend && npm run dev             # :3001  backend
cd hannah-frontend && npm run dev            # :5173  UI  → open it in the browser
```

**From your phone / another computer on the network:** go to `https://<pc-ip>:5173` (accept the
self-signed certificate). Vite proxies to the backend, so everything works, terminal included.

---

## 7. Checking it all came out right

```bash
curl -s localhost:3001/api/v1/health          # backend
curl -s localhost:8002/health                 # TTS (says whether it's on CUDA or CPU)
curl -s localhost:8005/health                 # gestures
curl -s localhost:11434/api/tags              # Ollama models
```

Then, in the interface: say something to her. You should get **written answer + voice + movement**.

| If missing… | Symptom |
|---|---|
| Kokoro weights | replies in text but **you hear nothing** |
| the motion-lab's `runs/*.pt` | speaks but **doesn't gesture** while speaking |
| Ollama / the model | **no answer at all** |
| ASR sidecar | doesn't understand you by voice (text does work) |

---

## 8. The floating overlay on your desktop

**Start here:**

```bash
./hannah doctor      # tells you whether your environment supports the overlay, and what's missing
```

Hannah can float **on top of everything** on any desktop, but how she gets there depends on the
setup:

| Desktop / session | How it floats | What you need |
|---|---|---|
| **Hyprland** | native (`hyprctl`) | nothing |
| **KDE Plasma** (Wayland or X11) | KWin | `kdotool` (recommended) or `wmctrl` |
| **GNOME, XFCE, Cinnamon, MATE, i3** (X11) | standard EWMH | `wmctrl` |
| **GNOME/KDE on Wayland** | via **XWayland** | use the **desktop app** (it forces XWayland) |
| **Windows / macOS** | native (Electron) | nothing |

> **Why XWayland:** on *native* Wayland the protocol **forbids** an app from putting itself
> on top or moving itself (that's a Wayland design decision, not a bug). That's why the desktop
> app starts forced onto XWayland (`ozone-platform=x11`), where the window is a real X11 one
> and every compositor respects "always on top". If you want to experiment with native
> Wayland: `HANNAH_OZONE=wayland` — but you lose floating and moving between monitors.

**The most portable route** is the desktop app, which already has it all solved:

```bash
cd hannah-frontend && npm run build          # builds the dist that the app bundles
cd ../hannah-desktop && npm install && npm start
```

Also install `wmctrl` (or `kdotool` on KDE) so Hannah can **move by voice**
("andá al centro", "pasate a la otra pantalla"):

```bash
sudo pacman -S wmctrl        # Arch/CachyOS
sudo apt install wmctrl      # Debian/Ubuntu
sudo dnf install wmctrl      # Fedora
```

**If it doesn't float on your desktop:** run `./hannah doctor`, which tells you exactly what's
missing. And if you're on GNOME Wayland and it still doesn't float even with the app, report it
with the output of `wmctrl -l` and `xprop -name Hannah _NET_WM_STATE` (see checklist below).

### Checklist to verify on your machine (if it's not Hyprland)

```bash
./hannah doctor                              # 1. verdict on your environment
wmctrl -l | grep -i hannah                   # 2. is the window visible to X11?
xprop -name Hannah _NET_WM_STATE             # 3. does _NET_WM_STATE_ABOVE show up?
```
Open another maximized window on top: Hannah should stay visible in front.

## 8b. Shutting Hannah down (and getting the VRAM back)

The sidecars and the loaded models **hold on to GPU memory for as long as they live** — in a
typical session that's about 14GB. So:

```bash
./hannah stop               # shuts down app, backend, sidecars, Vite and unloads Ollama's models
./hannah stop --dry-run     # shows what it would kill, without touching anything
./hannah stop --keep-ollama # leaves the models warm (faster start next time)
```

**Closing the overlay window does the same thing automatically** if you opened it with `./hannah`.
If you started it by hand (`npm run start:dev`), closing it does NOT shut anything down — that way
it doesn't tear down services you were using for testing.

If Ollama runs as a systemd service (the norm on Arch/CachyOS), the script **cannot** bring the
service down because it runs as another user: it unloads the models from VRAM, which is what takes
up the space, and prints the command in case you want to stop it entirely
(`sudo systemctl stop ollama`).

## 9. Security — read this before enabling the terminal

`TOOLS_SYSTEM_CONTROL=true` gives Hannah a **real shell** on your machine (the same one the ⌨
panel uses). **There is no command allowlist**: it can run anything. The only safety net is that
destructive commands (`rm`, `dd`, `mkfs`, `shutdown`, `git --force`…) **ask you for confirmation**
in a modal — that's *best-effort*, not a security barrier.

If you don't need it, leave it at `false`: Hannah still converses, sees through the camera,
searches the internet and opens pages.

Don't share your `hannah-backend/.env` or `hannah-backend/data/` either (that's where the API keys
and your conversation memory live); they're already gitignored.

---

## 10. Common problems

**`npm install` fails on the frontend** (`ERESOLVE`) → use `--legacy-peer-deps`. It's a known
conflict between vite 5 and `@vitejs/plugin-basic-ssl`.

**Super+H does nothing** → it's usually a Vite started by hand on HTTPS occupying `:5173`; the
overlay needs it on HTTP. Close it (`pkill -f 'bin/vite'`) and launch again; the launcher
warns you if it detects that case. Check `.hannah-launch.log` too.

**No voice** → make sure the TTS sidecar is up (`curl localhost:8002/health`) and that the
two Kokoro files are in `sidecar/tts/` with the exact name.

**Suddenly "no answer at all"** → make sure Ollama is running and that the model in `.env` exists
(`ollama list`).

**The microphone doesn't work over the LAN** → the browser requires HTTPS outside localhost; use
`https://<ip>:5173` (not `http://`) and accept the certificate.

**The desktop app doesn't start: `Error: spawn .../electron/dist/electron ENOENT`** (check whether
the path in the error ends in `\n`) → the file `node_modules/electron/path.txt` ended up with a
line break and Electron reads it without trimming it. It happens when the binary was installed by
hand (postinstall blocked). Fix it with:
```bash
cd hannah-desktop && printf 'electron' > node_modules/electron/path.txt
```
If the binary is missing as well (`dist/electron` doesn't exist), reinstall allowing the
postinstall: `npm rebuild electron` or `npm install electron --force`.

**Everything is slow** → check whether the sidecars are on CPU: `curl -s localhost:8002/health` says
the provider. Without CUDA, the TTS is the bottleneck.

## macOS and Windows

Each has its own one-command install — everything lands in your user folder, **no admin**,
and anything you already have (git, node ≥ 20, uv, bun, ollama) is reused instead of reinstalled:

```bash
# macOS (Apple Silicon or Intel) — needs git (Xcode Command Line Tools)
curl -fsSL https://hannah-motion-lab.github.io/site/install-mac.sh | bash
```
```powershell
# Windows 10/11 (x64), in PowerShell
irm https://hannah-motion-lab.github.io/site/install.ps1 | iex
```

None of the installers touches Ollama or a language model. The **first time the overlay opens,
Hannah asks where she should think**: *on this PC* (she detects an Ollama you already have, or
installs one in your user folder and pulls `qwen2.5:7b`, `moondream` and `nomic-embed-text` with a
progress bar, if you press the button) or *a provider* (Groq / OpenAI / Anthropic / OpenRouter,
paste a key). Vision and memory recall follow that choice (on with a local brain, off with a
provider). It can be changed later in ⚙ → Brain. `GET /api/v1/brain` is the status behind it.

Afterwards `hannah` (launchers `hannah-mac` / `hannah.ps1` in this repo) brings up Ollama, the
voice and listening sidecars on the CPU, the backend and the overlay app; `hannah stop` and
`hannah doctor` work as on Linux. What differs from Linux: the voice runs on the CPU (~1–2 s per
sentence) and there is **no gesture model** (CUDA-only) — the avatar idles and looks around but
does not gesture while speaking. The Linux `hannah` launcher itself is Linux-only (it leans on
`ss`, `/proc`, `ip` and the X11/Hyprland adapters).

If you would rather do it by hand, this is what the installers do — the **overlay app** is built
for you ([releases](https://github.com/Hannah-Motion-Lab/desktop/releases/latest):
`Hannah-<version>-mac-arm64.dmg` (Apple Silicon), `-mac-x64.dmg` (Intel), `-win-x64.exe`), and
the rest of the stack goes in your user folder:

- **Node 20+** via [nvm](https://github.com/nvm-sh/nvm), **Python 3.12** via [uv](https://docs.astral.sh/uv/)
  (`uv venv .venv --python 3.12`), **bun** for the hands.
- **Ollama**: the desktop app. On macOS drag it to `~/Applications` (not `/Applications`) and
  decline the "install CLI" step (that is the one prompt that wants admin); the binary is at
  `~/Applications/Ollama.app/Contents/Resources/ollama`. Then `ollama pull qwen2.5:7b`.
- **Sidecars on CPU**: `sidecar/requirements.txt` pins `onnxruntime-gpu`, which has no macOS
  wheel — swap it for `onnxruntime` (`sed 's/onnxruntime-gpu==.*/onnxruntime/' requirements.txt > req-cpu.txt`)
  and run the TTS with `TTS_DEVICE=cpu`. Whisper runs on CPU as is. Expect ~1–2 s per sentence
  for the voice on Apple Silicon.
- **No gestures**: the motion model is CUDA-only; set `MOTION_ENABLED=false` in `.env` and the
  procedural idle takes over.
- **Run it** (four terminals from `hannah-backend`): `TTS_DEVICE=cpu npm run sidecar:tts`,
  `npm run sidecar:asr`, `npm run dev`; then `HANNAH_HTTP=1 npm run dev` in `hannah-frontend`
  and open the overlay app (or `HANNAH_DEV=1 npm start` in `hannah-desktop` to use the dev server).
- **Unsigned builds.** macOS quarantines the download and says the app "can't be opened":
  `xattr -dr com.apple.quarantine ~/Applications/Hannah.app` fixes it without admin (you own the
  file). Windows SmartScreen: "More info → Run anyway". An app you build yourself
  (`npm run build:mac` / `build:win` in `hannah-desktop`) carries no quarantine at all.
- The overlay talks to the backend at `http://localhost:3001`, so everything above must be
  running on the same machine. Floating on top and moving between monitors use Electron's own
  API there (no compositor tools needed).
