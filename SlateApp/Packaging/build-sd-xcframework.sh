#!/usr/bin/env bash
set -euo pipefail
# Build leejet/stable-diffusion.cpp with Metal into Frameworks/sd.xcframework —
# same idea as llama.xcframework: one merged static lib + headers + modulemap so
# SlateDiffusion can `import sd`. cmake comes from the slate build venv.
# The clone+build is cached so re-runs are incremental (only re-links the xcfw).
cd "$(dirname "$0")/../.."   # -> repo root
ROOT="$(pwd)"
CMAKE="${CMAKE:-$HOME/.slate-build-venv/bin/cmake}"
test -x "$CMAKE" || { echo "[sd] cmake not found at $CMAKE"; exit 1; }

CACHE="$HOME/Library/Caches/slate-sd"
SRC="$CACHE/stable-diffusion.cpp"
source "$ROOT/SlateApp/Packaging/release-artifacts.env"
mkdir -p "$CACHE"
if [ -d "$SRC/.git" ]; then
    echo "[sd] reusing cached clone at $SRC"
else
    echo "[sd] cloning stable-diffusion.cpp -> $SRC"
    git clone --filter=blob:none --no-checkout https://github.com/leejet/stable-diffusion.cpp "$SRC"
fi
test -z "$(git -C "$SRC" status --porcelain)" || {
    echo "[sd] cached source has local changes; refusing a non-reproducible build" >&2
    exit 1
}
if ! git -C "$SRC" cat-file -e "$SD_SOURCE_REVISION^{commit}" 2>/dev/null; then
    git -C "$SRC" fetch --depth 1 origin "$SD_SOURCE_REVISION"
fi
git -C "$SRC" checkout --detach "$SD_SOURCE_REVISION"
git -C "$SRC" submodule update --init --recursive --depth 1
test "$(git -C "$SRC" rev-parse HEAD)" = "$SD_SOURCE_REVISION"

echo "[sd] configuring (Metal, static, embedded metallib)…"
"$CMAKE" -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSD_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DSD_BUILD_SHARED_LIBS=OFF \
    -DSD_BUILD_EXAMPLES=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64

echo "[sd] building…"
"$CMAKE" --build "$SRC/build" --config Release -j"$(sysctl -n hw.ncpu)"

echo "[sd] merging + localizing static libs…"
STAGE="$(mktemp -d)"
# CRITICAL: Slate also links llama.xcframework, which bundles a DIFFERENT ggml and
# exports ~1270 ggml symbols. Without this step sd.cpp's ggml calls bind to llama's
# ggml at runtime (e.g. ggml_abort) → ABI mismatch → SIGABRT mid-generation. Fix:
# relocatably relink all sd objects, keeping ONLY the stable-diffusion C API global
# and localizing everything else (ggml/gguf) so sd uses its OWN ggml.
cat > "$STAGE/sd_api.txt" <<'API'
_sd_*
_new_sd_ctx
_free_sd_ctx
_free_sd_audio
_generate_image
_generate_video
_str_to_*
API
LIBS="$(find "$SRC/build" -name '*.a' -type f)"
FORCE=""; for l in $LIBS; do FORCE="$FORCE -force_load $l"; done
ld -r -arch arm64 -platform_version macos 26.0 26.0 $FORCE \
   -exported_symbols_list "$STAGE/sd_api.txt" -o "$STAGE/libsd-local.o"
# Darwin archives normally record the current timestamp, which makes an
# otherwise identical framework hash change on every build.
ZERO_AR_DATE=1 libtool -static -o "$STAGE/libsd.a" "$STAGE/libsd-local.o"

echo "[sd] assembling headers + modulemap…"
mkdir -p "$STAGE/include"
cp "$SRC/include/stable-diffusion.h" "$STAGE/include/"
printf 'module sd {\n    header "stable-diffusion.h"\n    link "c++"\n    export *\n}\n' > "$STAGE/include/module.modulemap"

echo "[sd] creating xcframework…"
rm -rf "$ROOT/Frameworks/sd.xcframework"
xcodebuild -create-xcframework \
    -library "$STAGE/libsd.a" -headers "$STAGE/include" \
    -output "$ROOT/Frameworks/sd.xcframework"
cp "$SRC/include/stable-diffusion.h" "$ROOT/Frameworks/stable-diffusion.h"
bash "$ROOT/SlateApp/Packaging/verify-native-artifacts.sh"
echo "[sd] done -> Frameworks/sd.xcframework"
