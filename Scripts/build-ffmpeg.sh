#!/bin/bash
set -euo pipefail

readonly FFMPEG_VERSION="7.1.2"
readonly FFMPEG_SHA256="089bc60fb59d6aecc5d994ff530fd0dcb3ee39aa55867849a2bbc4e555f9c304"
readonly AOM_VERSION="3.12.1"
readonly AOM_SHA256="9e9775180dec7dfd61a79e00bda3809d43891aee6b2e331ff7f26986207ea22e"
readonly VPX_VERSION="1.15.2"
readonly VPX_SHA256="26fcd3db88045dee380e581862a6ef106f49b74b6396ee95c2993a260b4636aa"
readonly DEPLOYMENT_TARGET="14.0"

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly OUTPUT_DIR="$ROOT_DIR/Vendor/ffmpeg/ReelFFmpeg.xcframework"
readonly WORK_DIR="$(mktemp -d /tmp/reel-ffmpeg-build.XXXXXX)"
readonly CODEC_PREFIX="$WORK_DIR/codecs"
readonly FFMPEG_PREFIX="$WORK_DIR/ffmpeg-install"
readonly SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
readonly CLANG_PATH="$(xcrun --find clang)"
readonly CLANGXX_PATH="$(xcrun --find clang++)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command_name in curl cmake ninja make pkg-config shasum xcodebuild; do
    if ! command -v "$command_name" >/dev/null; then
        echo "Missing build dependency: $command_name" >&2
        exit 1
    fi
done

fetch() {
    local url="$1"
    local sha256="$2"
    local destination="$3"
    curl --fail --location --silent --show-error "$url" --output "$destination"
    local actual
    actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
    if [[ "$actual" != "$sha256" ]]; then
        echo "Checksum mismatch for $url" >&2
        exit 1
    fi
}

mkdir -p "$WORK_DIR/sources/vpx" "$WORK_DIR/sources/aom" \
    "$WORK_DIR/sources/ffmpeg" "$WORK_DIR/build/vpx" "$WORK_DIR/build/aom" \
    "$WORK_DIR/framework" "$CODEC_PREFIX"

fetch \
    "https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX_VERSION.tar.gz" \
    "$VPX_SHA256" \
    "$WORK_DIR/libvpx.tar.gz"
fetch \
    "https://storage.googleapis.com/aom-releases/libaom-$AOM_VERSION.tar.gz" \
    "$AOM_SHA256" \
    "$WORK_DIR/libaom.tar.gz"
fetch \
    "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
    "$FFMPEG_SHA256" \
    "$WORK_DIR/ffmpeg.tar.xz"

tar -xf "$WORK_DIR/libvpx.tar.gz" -C "$WORK_DIR/sources/vpx" --strip-components=1
tar -xf "$WORK_DIR/libaom.tar.gz" -C "$WORK_DIR/sources/aom" --strip-components=1
tar -xf "$WORK_DIR/ffmpeg.tar.xz" -C "$WORK_DIR/sources/ffmpeg" --strip-components=1

(
    cd "$WORK_DIR/build/vpx"
    SDKROOT="$SDK_PATH" \
        LDFLAGS="-isysroot $SDK_PATH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
        "$WORK_DIR/sources/vpx/configure" \
        --prefix="$CODEC_PREFIX" \
        --target=arm64-darwin23-gcc \
        --enable-shared \
        --disable-static \
        --disable-examples \
        --disable-tools \
        --disable-docs \
        --disable-unit-tests \
        --enable-vp9-highbitdepth \
        --extra-cflags="-isysroot $SDK_PATH -mmacosx-version-min=$DEPLOYMENT_TARGET"
    make -j"$(sysctl -n hw.ncpu)"
    make install
)

cmake \
    -S "$WORK_DIR/sources/aom" \
    -B "$WORK_DIR/build/aom" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CODEC_PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=1 \
    -DENABLE_TESTS=0 \
    -DENABLE_EXAMPLES=0 \
    -DENABLE_TOOLS=0 \
    -DENABLE_DOCS=0 \
    -DENABLE_TESTDATA=0 \
    -DCONFIG_AV1_ENCODER=1 \
    -DCONFIG_AV1_DECODER=1
cmake --build "$WORK_DIR/build/aom" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$WORK_DIR/build/aom"

(
    cd "$WORK_DIR/sources/ffmpeg"
    export PKG_CONFIG_PATH="$CODEC_PREFIX/lib/pkgconfig"
    ./configure \
        --prefix="$FFMPEG_PREFIX" \
        --arch=arm64 \
        --target-os=darwin \
        --cc="$CLANG_PATH" \
        --cxx="$CLANGXX_PATH" \
        --host-cc="$CLANG_PATH" \
        --host-cflags="-isysroot $SDK_PATH" \
        --pkg-config="$(command -v pkg-config)" \
        --install-name-dir=@rpath \
        --disable-gpl \
        --disable-nonfree \
        --enable-shared \
        --disable-static \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-network \
        --disable-autodetect \
        --disable-avdevice \
        --disable-avfilter \
        --disable-iconv \
        --enable-libvpx \
        --enable-libaom \
        --enable-videotoolbox \
        --enable-audiotoolbox \
        --enable-bzlib \
        --enable-zlib \
        --extra-cflags="-isysroot $SDK_PATH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
        --extra-cxxflags="-isysroot $SDK_PATH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
        --extra-ldflags="-isysroot $SDK_PATH -mmacosx-version-min=$DEPLOYMENT_TARGET -L$CODEC_PREFIX/lib"
    make -j"$(sysctl -n hw.ncpu)"
    make install
)

readonly FRAMEWORK_DIR="$WORK_DIR/framework/ReelFFmpeg.framework"
readonly VERSION_DIR="$FRAMEWORK_DIR/Versions/A"
mkdir -p "$VERSION_DIR/Headers" "$VERSION_DIR/Modules" \
    "$VERSION_DIR/Resources" "$VERSION_DIR/Frameworks"

"$CLANG_PATH" \
    -dynamiclib "$ROOT_DIR/Vendor/ffmpeg/bridge/ReelFFmpeg.c" \
    -I "$ROOT_DIR/Vendor/ffmpeg/bridge/include" \
    -I "$FFMPEG_PREFIX/include" \
    -L "$FFMPEG_PREFIX/lib" \
    -L "$CODEC_PREFIX/lib" \
    -lavformat -lavcodec -lswscale -lswresample -lavutil \
    -framework VideoToolbox -framework AudioToolbox \
    -framework CoreMedia -framework CoreVideo -framework CoreFoundation \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -Wl,-install_name,@rpath/ReelFFmpeg.framework/Versions/A/ReelFFmpeg \
    -Wl,-rpath,@loader_path/Frameworks \
    -o "$VERSION_DIR/ReelFFmpeg"

cp "$ROOT_DIR/Vendor/ffmpeg/bridge/include/ReelFFmpeg.h" "$VERSION_DIR/Headers/"
cp "$ROOT_DIR/Vendor/ffmpeg/bridge/module.modulemap" "$VERSION_DIR/Modules/"
cp "$ROOT_DIR/Vendor/ffmpeg/bridge/Info.plist" "$VERSION_DIR/Resources/"

copy_library() {
    local source="$1"
    local name="$2"
    cp -L "$source" "$VERSION_DIR/Frameworks/$name"
    install_name_tool -id "@rpath/$name" "$VERSION_DIR/Frameworks/$name"
    install_name_tool -add_rpath @loader_path "$VERSION_DIR/Frameworks/$name" 2>/dev/null || true
}

copy_library "$FFMPEG_PREFIX/lib/libavformat.61.dylib" "libavformat.61.dylib"
copy_library "$FFMPEG_PREFIX/lib/libavcodec.61.dylib" "libavcodec.61.dylib"
copy_library "$FFMPEG_PREFIX/lib/libswresample.5.dylib" "libswresample.5.dylib"
copy_library "$FFMPEG_PREFIX/lib/libswscale.8.dylib" "libswscale.8.dylib"
copy_library "$FFMPEG_PREFIX/lib/libavutil.59.dylib" "libavutil.59.dylib"
copy_library "$CODEC_PREFIX/lib/libvpx.11.dylib" "libvpx.11.dylib"
copy_library "$CODEC_PREFIX/lib/libaom.3.dylib" "libaom.3.dylib"

for library in "$VERSION_DIR/Frameworks"/libav*.dylib; do
    install_name_tool -change libvpx.11.dylib @rpath/libvpx.11.dylib "$library" 2>/dev/null || true
done

ln -s A "$FRAMEWORK_DIR/Versions/Current"
ln -s Versions/Current/ReelFFmpeg "$FRAMEWORK_DIR/ReelFFmpeg"
ln -s Versions/Current/Headers "$FRAMEWORK_DIR/Headers"
ln -s Versions/Current/Modules "$FRAMEWORK_DIR/Modules"
ln -s Versions/Current/Resources "$FRAMEWORK_DIR/Resources"
ln -s Versions/Current/Frameworks "$FRAMEWORK_DIR/Frameworks"

readonly TEMP_OUTPUT="$WORK_DIR/ReelFFmpeg.xcframework"
xcodebuild -create-xcframework \
    -framework "$FRAMEWORK_DIR" \
    -output "$TEMP_OUTPUT"

rm -rf "$OUTPUT_DIR"
cp -R "$TEMP_OUTPUT" "$OUTPUT_DIR"
echo "Built $OUTPUT_DIR"
