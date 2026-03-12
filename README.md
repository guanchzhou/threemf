<p align="center">
  <img src="icon.png" width="128" height="128" alt="threemf icon">
</p>

<h1 align="center">threemf</h1>

<p align="center">
  <a href="https://github.com/guanchzhou/threemf/releases/latest"><img src="https://img.shields.io/github/v/release/guanchzhou/threemf?style=flat-square&color=blue" alt="Release"></a>
  <a href="https://github.com/guanchzhou/threemf/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/guanchzhou/threemf/test.yml?style=flat-square&label=tests" alt="Tests"></a>
  <a href="https://github.com/guanchzhou/threemf/actions/workflows/codeql.yml"><img src="https://img.shields.io/github/actions/workflow/status/guanchzhou/threemf/codeql.yml?style=flat-square&label=CodeQL" alt="CodeQL"></a>
  <a href="https://github.com/guanchzhou/threemf/blob/main/LICENSE"><img src="https://img.shields.io/github/license/guanchzhou/threemf?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026+-black?style=flat-square&logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/arch-Apple%20Silicon-black?style=flat-square&logo=apple" alt="Apple Silicon">
  <a href="https://github.com/guanchzhou/threemf/releases/latest"><img src="https://img.shields.io/github/downloads/guanchzhou/threemf/total?style=flat-square&color=green" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/SLSA-Level%203-brightgreen?style=flat-square" alt="SLSA L3">
</p>

<p align="center">Quick Look plugin for previewing <code>.3mf</code> and <code>.stl</code> 3D printing files on macOS.<br>Press Space in Finder to see interactive 3D previews — no need to open a slicer.</p>

## Features

- Interactive 3D preview with mouse rotation, pan, and zoom
- Supports `.3mf` (Bambu Lab, PrusaSlicer, etc.) and `.stl` (binary and ASCII)
- Falls back to embedded thumbnail for `.3mf` files when 3D parsing fails
- Signed and notarized for easy distribution

<p align="center">
  <img src="images/demo-orbit.gif" width="300" alt="Orbit">
  <img src="images/demo-pan.gif" width="300" alt="Pan & Zoom">
</p>

## Install

### Homebrew

```
brew install --cask guanchzhou/tap/threemf
```

### Manual

1. Download `threemf.zip` from [Releases](https://github.com/guanchzhou/threemf/releases)
2. Unzip and move `threemf.app` to `/Applications/`
3. Open the app once to register the Quick Look extensions

## Requirements

macOS 26 (Tahoe) or later. Apple Silicon only.

## Build from source

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
brew install xcodegen
xcodegen generate
xcodebuild -scheme ThreeMFQuickLook -configuration Release build
```

### Building for older macOS versions

Official releases target macOS 26+, but the code is compatible with macOS 14 (Sonoma) and later. To build for an older version, override the deployment target:

```
xcodegen generate
xcodebuild -scheme ThreeMFQuickLook -configuration Release \
  MACOSX_DEPLOYMENT_TARGET=14.0 build
```

To include Intel support (universal binary):

```
xcodebuild -scheme ThreeMFQuickLook -configuration Release \
  MACOSX_DEPLOYMENT_TARGET=14.0 ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO build
```

> **Note:** Older versions are not tested in CI. If you encounter issues, please open an issue.

## License

MIT
