# Desktop packaging (unsigned / no-secrets)

These helpers produce **distributable archives without signing secrets**. They
are for CI artifacts, maintainer smoke, and community sideload — not store
submission.

| Script | Host | Output |
|---|---|---|
| `macos_dmg.sh` | macOS | `build/packaging/Telltale-<ver>-macos-unsigned.dmg` |
| `windows_zip.sh` | Windows | `build/packaging/Telltale-<ver>-windows-unsigned.zip` |
| `linux_tarball.sh` | Linux | `build/packaging/Telltale-<ver>-linux-<arch>.tar.gz` |

All accept `--skip-build` when a Release tree already exists.

## macOS DMG + notarization (called out, not automated)

```bash
tool/packaging/macos_dmg.sh
```

Gatekeeper will quarantine an unsigned DMG. Public distribution needs:

1. Developer ID Application certificate
2. `codesign --deep --force --options runtime …`
3. `xcrun notarytool submit … --wait`
4. `xcrun stapler staple Telltale.app` (and re-pack the DMG)

None of those steps belong in free public CI without storing Apple secrets.

## Windows zip vs MSIX

`windows_zip.sh` ships the Flutter Release runner folder. An MSIX stub (needs
a signing cert + `makeappx` / `Msix` tooling) looks like:

```powershell
# Stub only — requires a code-signing certificate.
flutter pub add msix --dev   # or use the msix package configuration
flutter pub run msix:create
# Output: build/windows/x64/runner/Release/*.msix
```

Do not commit certificate material. Until a community or store cert exists,
prefer the zip artifact from CI.

## Linux tarball vs AppImage / Flatpak

`linux_tarball.sh` packs Flutter's `bundle/` directory. Stubs:

**AppImage** (needs `appimagetool` + a `.desktop` file):

```bash
# After linux_tarball contents are extracted to AppDir/
#   AppDir/usr/bin/telltale -> bundle binary
#   AppDir/telltale.desktop
#   AppDir/telltale.png
appimagetool AppDir Telltale-x86_64.AppImage
```

**Flatpak** (needs a Flatpak manifest + runtime; Flathub review is separate):

```yaml
# com.cbstudio.telltale.yml (stub)
app-id: com.cbstudio.telltale
runtime: org.freedesktop.Platform
runtime-version: '24.08'
sdk: org.freedesktop.Sdk
command: telltale
finish-args:
  - --share=network
  - --socket=wayland
  - --socket=fallback-x11
  - --device=dri
  - --system-talk-name=org.bluez
modules:
  - name: telltale
    buildsystem: simple
    build-commands:
      - install -D telltale /app/bin/telltale
    sources:
      - type: dir
        path: bundle
```

BlueZ access matters for Linux BLE; Classic SPP remains product-gated.

## CI

Public `ImL1s/telltale` CI uploads unsigned desktop archives from the existing
Apple / Linux / Windows build jobs when those jobs already produce Release or
Debug trees — see `.github/workflows/ci.yml` (`actions/upload-artifact`). No
extra paid minutes beyond the builds already required for functional smoke.
