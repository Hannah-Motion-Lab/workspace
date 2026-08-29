# macOS: two upstream fixes

Two bugs make Hannah half-broken on **every** macOS install, and both are fixed upstream in one
commit each. Neither is a mystery any more - the root cause of each is quoted below with the
evidence that proves it.

* **Bug A** - the shipped `Hannah.app` carries **no code signature**, so macOS TCC refuses to even
  *ask* for the microphone or the camera. Hannah never hears anything and never says why.
  Fix goes in **`Hannah-Motion-Lab/desktop`** (and, as belt and braces for the DMGs already
  published, in **`Hannah-Motion-Lab/site`**).
* **Bug B** - `node-pty`'s `spawn-helper` arrives from npm without its executable bit, so every
  terminal session dies in `posix_spawnp`. Fix goes in **`Hannah-Motion-Lab/site`**.

Diagnosed on an Intel iMac18,2 running macOS 13.7.5, on `Hannah-1.0.10-mac-x64.dmg` installed with
`curl -fsSL https://hannah-motion-lab.github.io/site/install-mac.sh | bash`. Neither bug is
specific to that machine: A hits every unsigned build on every Mac, B hits every macOS install of
node-pty 1.1.0 on both arches.

---

## Bug A - an unsigned bundle can never get the microphone

### What happens

The user talks, Hannah does not react. There is **no permission prompt**, **no entry to switch on**
under System Settings → Privacy & Security → Microphone, and **no error in the overlay** - the
frontend's `Sin microfono:` banner only appears when `getUserMedia` *throws*, and here it never
does. The camera fails identically. It looks like a broken model or a broken mic; it is neither.

### Why

macOS keys microphone access to the entitlement `com.apple.security.device.audio-input`.
Entitlements live *inside* a code signature, so a bundle with no signature cannot carry one, and
`tccd` will not display a prompt it knows it would have to deny.

`NSMicrophoneUsageDescription` / `NSCameraUsageDescription` are **already correct** in the
`Info.plist` and are not the problem - a usage string is only the *text* of a prompt that TCC has
decided not to show.

### Evidence

The bundle as installed from the published DMG:

```
$ codesign -dv ~/Applications/Hannah.app
/Users/<you>/Applications/Hannah.app: code object is not signed at all
```

And `tccd` in the system log, saying it in as many words - note `identifier=<ID of InvalidCode>`,
which is literally how TCC refers to a process it cannot identify because nothing is signed:

```
tccd: Prompting policy for hardened runtime; service: kTCCServiceMicrophone requires entitlement
com.apple.security.device.audio-input but it is missing for responsible={TCCDProcess:
identifier=<ID of InvalidCode>, ..., responsible_path=/Users/<you>/Applications/Hannah.app/Contents/MacOS/Hannah}
tccd: Policy disallows prompt for Sub:{ai.hannah.desktop}Resp:{...}; access to kTCCServiceMicrophone denied
```

The same two lines appear for `kTCCServiceCamera`.

### Why the x64 DMG in particular

electron-builder only *forces* an ad-hoc signature for `arm64` output, because Apple Silicon
refuses to execute unsigned code at all. The `x64` output is left exactly as linked - unsigned -
which is what `Format=app bundle with Mach-O thin (x86_64)` + "not signed at all" shows above. And
even the automatic arm64 ad-hoc signature is not a fix here, because it carries **no entitlements**.
Both arches therefore need signing declared explicitly, with the entitlements file attached.

### Verified fix

Ad-hoc signing the installed bundle inside-out, with those entitlements, makes the prompt appear
and the microphone work. On the diagnosed machine, afterwards:

```
CodeDirectory v=20500 ... flags=0x10002(adhoc,runtime) ...
Signature=adhoc
/Users/<you>/Applications/Hannah.app: valid on disk
/Users/<you>/Applications/Hannah.app: satisfies its Designated Requirement
```

with `com.apple.security.device.audio-input` present in `codesign -d --entitlements -`, and all
four `Hannah Helper*.app` bundles carrying the same `adhoc,runtime` flags.

Ad-hoc signing needs **no Apple Developer account, no certificate and no admin**. It is not
notarization: downloads are still quarantined, so `xattr -dr com.apple.quarantine` is still needed
too. The two steps solve two different problems.

---

## Bug B - node-pty's `spawn-helper` is not executable

### What happens

Every terminal session in the ⌨ panel fails instantly. From `~/Hannah-Motion/.hannah-launch.log`:

```
error: Error ejecutando comando WebSocket posix_spawnp failed. {"action":"TERMINAL_START",
"sessionId":"f81296eb-...","stack":"    at new UnixTerminal
(/Users/<you>/Hannah-Motion/hannah-backend/node_modules/node-pty/lib/unixTerminal.js:92:24)"}
```

### Why

node-pty **1.1.0**'s npm tarball ships `prebuilds/darwin-x64/spawn-helper` and
`prebuilds/darwin-arm64/spawn-helper` at mode **0644 - not executable**:

```
-rw-r--r--  1 user  staff  9248  spawn-helper
```

`lib/unixTerminal.js:29` resolves the helper to exactly that prebuilt copy:

```js
var helperPath = native.dir + '/spawn-helper';
helperPath = path.resolve(__dirname, helperPath);
```

and `posix_spawnp` cannot execute a file without the executable bit. npm preserves the mode
recorded in the tarball, so this reproduces on a clean install on any Mac.

### Evidence (A/B/A)

Same machine, same session, nothing else changed:

| `spawn-helper` mode | `TERMINAL_START` |
| --- | --- |
| `644` (as shipped) | throws `posix_spawnp failed.` |
| `755` (`chmod +x`)  | works, shell opens |
| `644` (reverted)    | throws `posix_spawnp failed.` again |

The fix is one bit: `chmod +x`.

---

## Patch 1 - `Hannah-Motion-Lab/desktop`

Goal: `npm run build:mac` produces `Hannah-<version>-mac-arm64.dmg` and
`Hannah-<version>-mac-x64.dmg` that are ad-hoc signed **with the entitlements**, so a fresh install
is no longer `<ID of InvalidCode>` and the mic prompt appears by itself.

### 1a. New file: `build/entitlements.mac.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- TCC: without these two, macOS never even shows the permission prompt -->
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.apple.security.device.camera</key>
  <true/>
  <!-- Electron/V8 under the hardened runtime -->
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
```

### 1b. `package.json` → `build.mac`

Replace the existing `build.mac` block with this. `identity: "-"` is what makes electron-builder
sign ad-hoc instead of skipping signing; `entitlementsInherit` is what gets the same entitlements
onto the four `Hannah Helper*.app` bundles, which is where Chromium actually opens the audio device.

```json
  "build": {
    "appId": "ai.hannah.desktop",
    "productName": "Hannah",
    "artifactName": "Hannah-${version}-${os}-${arch}.${ext}",
    "mac": {
      "target": [
        { "target": "dmg", "arch": ["arm64", "x64"] }
      ],
      "category": "public.app-category.productivity",
      "identity": "-",
      "hardenedRuntime": true,
      "gatekeeperAssess": false,
      "notarize": false,
      "entitlements": "build/entitlements.mac.plist",
      "entitlementsInherit": "build/entitlements.mac.plist",
      "extendInfo": {
        "NSMicrophoneUsageDescription": "Hannah listens when you talk to her.",
        "NSCameraUsageDescription": "Hannah looks through the camera when you ask her to."
      }
    }
  }
```

Keep the rest of `build` (files, publish, win, linux…) as it is; only `mac` changes. Two things
that will silently undo this if they are present elsewhere:

* `"identity": null` anywhere in `mac` - that means *skip signing*, and it wins.
* `CSC_IDENTITY_AUTO_DISCOVERY=false` in the build environment or CI workflow - drop it, or the
  ad-hoc identity is never used.

### 1c. Verification, worth putting in CI so it cannot regress

```bash
npm run build:mac
for a in arm64 x64; do
  app="dist/mac$([ "$a" = x64 ] && echo -x64 || true)/Hannah.app"
  codesign -dv "$app" 2>&1 | grep -q 'Signature=adhoc' \
    || { echo "FAIL: $a is not signed"; exit 1; }
  codesign -d --entitlements - "$app" 2>/dev/null | grep -q 'com.apple.security.device.audio-input' \
    || { echo "FAIL: $a has no audio-input entitlement"; exit 1; }
done
echo "mac builds are ad-hoc signed with the mic/camera entitlements"
```

(Adjust the `dist/mac…` paths to whatever `electron-builder` actually emits for your two arches.)

### 1d. Note for the release notes

Users who already installed an older DMG keep the unsigned bundle until they reinstall. Patch 2
re-signs them in place; there is nothing to do by hand.

---

## Patch 2 - `Hannah-Motion-Lab/site` → `install-mac.sh`

Three edits against the current 239-line script. They fix Bug B for everyone and Bug A for the
DMGs that are already published, so users do not have to wait for a new release.

### 2a. Line 13 - the header comment is now wrong

It currently claims removing the quarantine flag is all an unsigned build needs:

```bash
#   5. the overlay app from the latest release (unsigned: the quarantine flag is removed)
```

Replace with:

```bash
#   5. the overlay app from the latest release (unsigned upstream: the quarantine flag is
#      removed AND the bundle is ad-hoc signed, or macOS never grants it the mic/camera)
```

### 2b. Section 4 - chmod node-pty's `spawn-helper`

In the `( cd "$ROOT/hannah-backend" … )` subshell, immediately after line 107
(`[ -d node_modules ] || npm install --no-audit --no-fund`), add:

```bash
  # node-pty 1.1.0 ships prebuilds/darwin-*/spawn-helper at 0644 in its npm tarball. posix_spawnp
  # cannot run a file without the executable bit, so EVERY terminal session dies with
  # "posix_spawnp failed." Unconditional on purpose: the `[ -d node_modules ] ||` above means a
  # re-run never reinstalls, so a package postinstall hook would never fire for existing users.
  chmod +x node_modules/node-pty/prebuilds/darwin-*/spawn-helper 2>/dev/null || true
```

**Do not** fold this into the `[ -d node_modules ] ||` short-circuit, and do not rely on a
`postinstall` in `hannah-backend/package.json` alone. On a re-run with `node_modules` already
present, `npm install` never runs and `postinstall` never fires - which is precisely the situation
of every user who is broken today. A `postinstall` covers fresh installs; this line covers the rest.

### 2c. Section 6 - ad-hoc sign the app, **outside** the version check

Add this **after the closing `fi` on line 203**, before `# ── 7. the launcher ──`.

The placement matters more than the code. The app install is wrapped in a version check (line 186):
if `~/Applications/Hannah.app` already exists at the same `CFBundleShortVersionString`, the script
prints `Hannah.app ✓ (already this version)` and skips the entire `else` branch - including the
`xattr` line. Putting the signing step inside that `else` would mean every existing user re-running
the installer, i.e. exactly the people stuck with an unsigned app right now, never gets signed.
Outside the `fi`, it runs on both paths; re-signing an already-signed bundle is harmless.

```bash
# ── 6b. the microphone: ad-hoc signature ──────────────────────────────────────────────
# The published DMGs carry NO code signature. macOS keys mic/camera access to the entitlement
# com.apple.security.device.audio-input; entitlements only exist inside a signature, so tccd
# refuses to even PROMPT ("Policy disallows prompt for ...; access to kTCCServiceMicrophone
# denied") and Hannah is deaf with no error anywhere. Ad-hoc signing needs no Apple account,
# no certificate and no admin. OUTSIDE the version check above on purpose: users who already
# have this version must be signed too, and re-signing is idempotent.
say "microphone + camera (ad-hoc signature)"
cat > "$tmp/hannah.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.device.camera</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
PLIST
if [ -d "$HOME/Applications/Hannah.app" ] && has codesign; then
  # inside-out: the nested helpers and frameworks first, the outer bundle last
  find "$HOME/Applications/Hannah.app/Contents/Frameworks" -depth \
       \( -name '*.app' -o -name '*.framework' -o -name '*.dylib' -o -name '*.node' \) \
       -exec codesign --force --sign - --options runtime \
                      --entitlements "$tmp/hannah.entitlements" {} \; 2>/dev/null || true
  codesign --force --sign - --options runtime --entitlements "$tmp/hannah.entitlements" \
           "$HOME/Applications/Hannah.app" 2>/dev/null || true
  if codesign -d --entitlements - "$HOME/Applications/Hannah.app" 2>/dev/null \
       | grep -q 'security\.device\.audio-input'; then
    sub "signed ✓ (macOS can now ask for the mic and the camera)"
  else
    warn "could not sign Hannah.app: macOS will never ask for the microphone. See ${DOCS}"
  fi
fi
```

No `sudo` anywhere: the bundle is in `$HOME/Applications` and the user owns it. `$tmp` is the
`mktemp -d` from line 58, already cleaned up by the `trap` on exit. `codesign` ships with the Xcode
Command Line Tools, which line 55 already requires for `git`; the `has codesign` guard keeps the
installer from failing if it is somehow absent.

macOS caches the TCC decision per bundle, so a user who was already denied should quit Hannah
completely and reopen her - the prompt then appears the first time she listens.

---

## Already done in `Hannah-Motion-Lab/workspace`

So the next person spends seconds, not hours:

* **`hannah-mac`** - `hannah doctor` now prints a `microphone :` line (is the app signed and does
  it carry `com.apple.security.device.audio-input`?) and a `terminal :` line (is
  `node-pty/prebuilds/darwin-<arch>/spawn-helper` executable?). Both bugs are now visible in one
  command instead of being invisible.
* **`SETUP.md`** - the "Unsigned builds" bullet no longer implies that removing the quarantine is
  all macOS needs; it documents the TCC consequence, the silent failure, and the signing recipe,
  and a new bullet covers the `spawn-helper` bit.
