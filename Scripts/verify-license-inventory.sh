#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL_PATTERN='\.(gguf|safetensors|mlmodelc|mlpackage|onnx|ort|tflite|pth|pt)$'
if find SlateApp Sources Tools -type f | grep -Ei "$MODEL_PATTERN" >/dev/null; then
  echo "Model weights found inside the Slate distribution source tree" >&2
  find SlateApp Sources Tools -type f | grep -Ei "$MODEL_PATTERN" >&2
  exit 1
fi

grep -F 'Model weights are not distributed with Slate' THIRD_PARTY_NOTICES.md >/dev/null
grep -F '| FluidAudio | 0.15.5' THIRD_PARTY_NOTICES.md >/dev/null
grep -F 'ripgrep | 15.1.0' THIRD_PARTY_NOTICES.md >/dev/null
grep -F 'NVIDIA Parakeet-TDT 0.6B v2' THIRD_PARTY_NOTICES.md >/dev/null
grep -F '| Supertone Supertonic |' THIRD_PARTY_NOTICES.md | grep -F 'OpenRAIL-M' >/dev/null
grep -F 'Curated optional model downloads' THIRD_PARTY_NOTICES.md >/dev/null
if grep -F 'flux2-klein-9b' SlateApp/ImageModelCatalog.swift >/dev/null; then
  echo "Non-commercial FLUX.2 klein weights must not appear in Slate's commercial download catalog" >&2
  exit 1
fi
test "$(find Licenses -type f | wc -l | tr -d '[:space:]')" -ge 5

test -f SlateApp/Help/Slate.help/Contents/Resources/en.lproj/index.html
test -f SlateApp/Help/Slate.help/Contents/Resources/de.lproj/index.html
grep -F 'content="com.langeundco.slate.help"' SlateApp/Help/Slate.help/Contents/Resources/en.lproj/index.html >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleHelpBookFolder' SlateApp/Packaging/Info.plist)" = "Slate.help"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleHelpBookName' SlateApp/Packaging/Info.plist)" = "com.langeundco.slate.help"

PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SlateUpdatePublicKey' SlateApp/Packaging/Info.plist)"
FEED="$(/usr/libexec/PlistBuddy -c 'Print :SlateUpdateFeedURL' SlateApp/Packaging/Info.plist)"
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]
[[ "$FEED" =~ ^https://[^[:space:]@]+$ ]]

echo "License/model distribution inventory verified."
