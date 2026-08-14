#!/usr/bin/env bash
# 构建自包含的 macOS libmpv.2.dylib：所有第三方依赖静态链入，产物仅依赖
# 系统库，可像 Windows 版 libmpv-2.dll 一样直接拷贝进应用目录使用。
# 包含本仓库特性：在线播放 ISO 光盘镜像、gpu-next render backend（杜比视界）。
#
# 用法:
#   ci/build-libmpv-macos.sh [arm64|x86_64|universal]   # 默认 arm64
#
# 环境变量:
#   WORK        构建目录（默认 ./build-macos-static）
#   MPV_SOURCE  mpv 源码目录（默认脚本所在仓库根目录）
#   FORCE       =1 时忽略 stamp 重新构建已完成的包
#
# 产物: $WORK/dist/libmpv.2.dylib（universal 时为 arm64+x86_64 双架构）

set -euo pipefail

ARCH_ARG="${1:-arm64}"
case "$ARCH_ARG" in
    arm64|x86_64) ARCHS=("$ARCH_ARG") ;;
    universal)    ARCHS=(arm64 x86_64) ;;
    *) echo "用法: $0 [arm64|x86_64|universal]" >&2; exit 1 ;;
esac

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MPV_SOURCE=${MPV_SOURCE:-$(cd "$SCRIPT_DIR/.." && pwd)}
WORK=${WORK:-$MPV_SOURCE/build-macos-static}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
DEPLOYMENT_TARGET=11.0
DIST=$WORK/dist

mkdir -p "$WORK/src" "$DIST"

# ---------------------------- 依赖版本与来源 ----------------------------

# libplacebo 锁定 v7.360.1：mpv meson 要求 >=7.360.1（本树验证过的最低版本）
SRC_LIBPLACEBO=https://github.com/haasn/libplacebo.git
TAG_LIBPLACEBO=v7.360.1

SRC_FFMPEG=https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz
SRC_LIBASS=https://github.com/libass/libass/releases/download/0.17.4/libass-0.17.4.tar.xz
SRC_FRIBIDI=https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz
SRC_HARFBUZZ=https://github.com/harfbuzz/harfbuzz/releases/download/11.4.2/harfbuzz-11.4.2.tar.xz
SRC_FREETYPE="https://sourceforge.net/projects/freetype/files/freetype2/2.13.3/freetype-2.13.3.tar.xz/download"
SRC_LIBPNG=https://downloads.sourceforge.net/project/libpng/libpng16/1.6.47/libpng-1.6.47.tar.xz
SRC_DAV1D=https://download.videolan.org/videolan/dav1d/1.5.1/dav1d-1.5.1.tar.xz
SRC_LIBBLURAY=https://download.videolan.org/pub/videolan/libbluray/1.5.0/libbluray-1.5.0.tar.xz
SRC_LIBDVDCSS=https://download.videolan.org/pub/videolan/libdvdcss/1.6.0/libdvdcss-1.6.0.tar.xz
SRC_LIBDVDREAD=https://download.videolan.org/pub/videolan/libdvdread/7.1.1/libdvdread-7.1.1.tar.xz
# libdvdnav 5.x/7.x 没有发布 tarball，用 git 标签（7.0.0 起使用 meson 构建）
SRC_LIBDVDNAV=https://code.videolan.org/videolan/libdvdnav.git
TAG_LIBDVDNAV=7.0.0
SRC_UCHARDET=https://gitlab.freedesktop.org/uchardet/uchardet/-/archive/v0.0.8/uchardet-v0.0.8.tar.gz
SRC_LCMS2=https://downloads.sourceforge.net/project/lcms/lcms/2.17/lcms2-2.17.tar.gz
SRC_LIBARCHIVE=https://github.com/libarchive/libarchive/releases/download/v3.8.2/libarchive-3.8.2.tar.xz
# mbedtls 3.6 LTS 给 ffmpeg 提供 https（ffmpeg 已移除 macOS 的 SecureTransport
# 后端）。其 CMake 需要 git 元数据确定版本，不能用 GitHub 自动归档。
SRC_MBEDTLS=https://github.com/Mbed-TLS/mbedtls.git
TAG_MBEDTLS=v3.6.5

# ---------------------------- 通用工具函数 ----------------------------

# 日志一律走 stderr：fetch() 的返回值经命令替换从 stdout 捕获
log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> [git-tag]
    local url=$1 tag=${2:-} dir archive name topdir
    # sourceforge 下载直链以 /download 结尾，真实文件名在其之前
    name=$(basename "${url%/download}")
    name=${name%%\?*}
    dir=$WORK/src/$name
    dir=${dir%.tar.gz}; dir=${dir%.tar.xz}; dir=${dir%.tar.bz2}; dir=${dir%.git}
    if [[ -n $tag ]]; then
        if [[ ! -d $dir ]]; then
            log "克隆 $url (tag $tag)"
            git clone --depth 1 --branch "$tag" --recurse-submodules --shallow-sub-modules \
                "$url" "$dir"
        fi
        printf '%s' "$dir"; return
    fi
    if [[ ! -d $dir ]]; then
        archive=$WORK/src/$name
        log "下载 $url"
        curl -fL --retry 3 -o "$archive" "$url"
        topdir=$(tar tf "$archive" | head -1 | cut -d/ -f1)
        case "$archive" in
            *.tar.gz)  tar xzf "$archive" -C "$WORK/src" ;;
            *.tar.xz)  tar xJf "$archive" -C "$WORK/src" ;;
            *.tar.bz2) tar xjf "$archive" -C "$WORK/src" ;;
        esac
        # 归档顶层目录与文件名不一致时（如 GitHub 的 v3.6.5.tar.gz
        # 解出 mbedtls-3.6.5），重命名成预期名字
        if [[ ! -d $dir && -n $topdir && -d $WORK/src/$topdir ]]; then
            mv "$WORK/src/$topdir" "$dir"
        fi
    fi
    printf '%s' "$dir"
}

stamp() { printf '%s/stamps/%s' "$1" "$2"; }

done_pkg() { [[ -f $(stamp "$1" "$2") ]] && [[ ${FORCE:-0} != 1 ]]; }
mark_pkg() { mkdir -p "$1/stamps"; touch "$(stamp "$1" "$2")"; }

# ---------------------------- 构建体系封装 ----------------------------
# 全部依赖装进 per-arch PREFIX，只产出静态库；系统动态库（libz/libbz2/
# liblzma/libiconv，均在 /usr/lib，任何 Mac 都有）除外。

setup_env() { # setup_env <arch> <prefix>
    local arch=$1 prefix=$2
    # CC 保持纯净（meson/cmake 不喜欢带参数的 CC），架构统一走 CFLAGS/LDFLAGS
    export CC=clang
    export CXX=clang++
    COMMON_FLAGS="-O2 -arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET -fPIC"
    export CFLAGS=$COMMON_FLAGS
    export CXXFLAGS=$COMMON_FLAGS
    export LDFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET"
    # 隔离 pkg-config：只看本 prefix，避免混入 brew/runner 的库
    export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig
    export PKG_CONFIG_PATH=
    export MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET
}

write_meson_crossfile() { # write_meson_crossfile <arch> <file>
    cat >"$2" <<EOF
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[properties]
c_args = ['-O2', '-arch', '$1', '-mmacosx-version-min=$DEPLOYMENT_TARGET', '-fPIC']
c_link_args = ['-arch', '$1', '-mmacosx-version-min=$DEPLOYMENT_TARGET']
cpp_args = ['-O2', '-arch', '$1', '-mmacosx-version-min=$DEPLOYMENT_TARGET', '-fPIC']
cpp_link_args = ['-arch', '$1', '-mmacosx-version-min=$DEPLOYMENT_TARGET']

[host_machine]
system = 'darwin'
cpu_family = '$1'
cpu = '$1'
endian = 'little'
EOF
}

setup_env_is_cross() { [[ -n ${CROSSFILE:-} ]]; }

build_meson() { # build_meson <srcdir> <prefix> <pkgname> [extra meson args...]
    local src=$1 prefix=$2 name=$3; shift 3
    done_pkg "$prefix" "$name" && { log "跳过 ${name}（已完成）"; return; }
    log "meson 构建 $name"
    local bdir=$WORK/build-$name-$(basename "$prefix")
    rm -rf "$bdir"
    local -a setup=(meson setup "$bdir" "$src" --prefix="$prefix"
                    --default-library=static --buildtype=release
                    -Dpkgconfig.relocatable=true)
    if setup_env_is_cross; then setup+=(--cross-file "$CROSSFILE"); fi
    setup+=("$@")
    "${setup[@]}"
    ninja -C "$bdir" install
    mark_pkg "$prefix" "$name"
}

build_autotools() { # build_autotools <srcdir> <prefix> <pkgname> [extra configure args...]
    local src=$1 prefix=$2 name=$3; shift 3
    done_pkg "$prefix" "$name" && { log "跳过 ${name}（已完成）"; return; }
    log "configure 构建 $name"
    local bdir=$WORK/build-$name-$(basename "$prefix")
    rm -rf "$bdir" && mkdir -p "$bdir"
    (cd "$bdir" && "$src/configure" --prefix="$prefix" \
        --disable-shared --enable-static --with-pic --silent "$@")
    make -C "$bdir" -j"$JOBS" --no-print-directory
    make -C "$bdir" --no-print-directory install
    mark_pkg "$prefix" "$name"
}

build_cmake() { # build_cmake <srcdir> <prefix> <pkgname> <arch> [extra cmake args...]
    local src=$1 prefix=$2 name=$3 arch=$4; shift 4
    done_pkg "$prefix" "$name" && { log "跳过 ${name}（已完成）"; return; }
    log "cmake 构建 $name"
    local bdir=$WORK/build-$name-$(basename "$prefix")
    rm -rf "$bdir"
    cmake -S "$src" -B "$bdir" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        "$@" >/dev/null
    cmake --build "$bdir" --parallel "$JOBS" >/dev/null
    cmake --install "$bdir" >/dev/null
    mark_pkg "$prefix" "$name"
}

# ---------------------------- 单架构构建 ----------------------------

build_arch() { # build_arch <arch>
    local arch=$1
    local prefix=$WORK/prefix-$arch
    mkdir -p "$prefix"

    CROSSFILE=
    if [[ $arch != "$(uname -m)" ]]; then
        CROSSFILE=$WORK/cross-$arch.meson
        write_meson_crossfile "$arch" "$CROSSFILE"
    fi

    log "===== [$arch] 准备环境 ====="
    setup_env "$arch" "$prefix"

    # 1. 字体渲染链: libpng -> freetype -> fribidi -> harfbuzz -> libass
    build_cmake "$(fetch "$SRC_LIBPNG")" "$prefix" libpng "$arch" \
        -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF

    local d_freetype d_fribidi d_harfbuzz d_libass
    d_freetype=$(fetch "$SRC_FREETYPE")
    d_fribidi=$(fetch "$SRC_FRIBIDI")
    d_harfbuzz=$(fetch "$SRC_HARFBUZZ")
    d_libass=$(fetch "$SRC_LIBASS")
    if [[ -f $d_freetype/meson.build ]]; then
        build_meson "$d_freetype" "$prefix" freetype \
            -Dzlib=enabled -Dpng=enabled -Dbzip2=disabled -Dbrotli=disabled \
            -Dharfbuzz=disabled
    else
        build_autotools "$d_freetype" "$prefix" freetype \
            --with-bzip2=no --with-brotli=no --with-harfbuzz=no
    fi
    build_meson "$d_fribidi" "$prefix" fribidi -Ddocs=false
    build_meson "$d_harfbuzz" "$prefix" harfbuzz \
        -Dglib=disabled -Dgobject=disabled -Dicu=disabled -Dcairo=disabled \
        -Dtests=disabled -Ddocs=disabled -Dutilities=disabled
    build_meson "$d_libass" "$prefix" libass \
        -Dfontconfig=disabled -Dcoretext=enabled -Dtest=disabled

    # 2. AV1 软解
    build_meson "$(fetch "$SRC_DAV1D")" "$prefix" dav1d

    # 3. https 所需 TLS（ffmpeg 用 mbedtls）
    build_cmake "$(fetch "$SRC_MBEDTLS" "$TAG_MBEDTLS")" "$prefix" mbedtls "$arch" \
        -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DENABLE_EXAMPLES=OFF \
        -DGEN_FILES=OFF

    # 4. ffmpeg（静态，禁用自动探测保证配料可控；硬解走 VideoToolbox）
    local d_ffmpeg; d_ffmpeg=$(fetch "$SRC_FFMPEG")
    done_pkg "$prefix" ffmpeg && { log "跳过 ffmpeg（已完成）"; } || {
        log "构建 ffmpeg"
        local bdir=$WORK/build-ffmpeg-$arch
        rm -rf "$bdir" && mkdir -p "$bdir"
        (cd "$bdir" && "$d_ffmpeg/configure" \
            --prefix="$prefix" \
            --disable-shared --enable-static --enable-pic \
            --disable-programs --disable-doc --disable-debug \
            --disable-autodetect \
            --enable-gpl \
            --enable-zlib --enable-bzlib --enable-lzma \
            --enable-iconv \
            --enable-libdav1d \
            --enable-mbedtls \
            --enable-videotoolbox \
            --extra-cflags="-mmacosx-version-min=$DEPLOYMENT_TARGET -arch $arch" \
            --extra-ldflags="-mmacosx-version-min=$DEPLOYMENT_TARGET -arch $arch")
        make -C "$bdir" -j"$JOBS" >/dev/null
        make -C "$bdir" install >/dev/null
        mark_pkg "$prefix" ffmpeg
    }

    # 5. 光盘: libbluray / dvdcss / dvdread / dvdnav（在线 ISO 播放需要）
    local d_bluray d_dvdcss d_dvdread d_dvdnav
    d_bluray=$(fetch "$SRC_LIBBLURAY")
    d_dvdcss=$(fetch "$SRC_LIBDVDCSS")
    d_dvdread=$(fetch "$SRC_LIBDVDREAD")
    d_dvdnav=$(fetch "$SRC_LIBDVDNAV" "$TAG_LIBDVDNAV")
    if [[ -f $d_bluray/meson.build ]]; then
        build_meson "$d_bluray" "$prefix" libbluray \
            -Denable_examples=false -Denable_tools=false \
            -Dfontconfig=disabled -Dfreetype=disabled -Dlibxml2=disabled \
            -Dembed_udfread=true
    else
        build_autotools "$d_bluray" "$prefix" libbluray \
            --disable-bdjava-jar --without-libxml2 --without-freetype
    fi
    build_autotools "$d_dvdcss" "$prefix" libdvdcss
    if [[ -f $d_dvdread/meson.build ]]; then
        build_meson "$d_dvdread" "$prefix" libdvdread
    else
        build_autotools "$d_dvdread" "$prefix" libdvdread
    fi
    if [[ -f $d_dvdnav/meson.build ]]; then
        build_meson "$d_dvdnav" "$prefix" libdvdnav
    else
        build_autotools "$d_dvdnav" "$prefix" libdvdnav
    fi

    # 6. 其它: uchardet / lcms2 / libarchive
    build_cmake "$(fetch "$SRC_UCHARDET")" "$prefix" uchardet "$arch" \
        -DBUILD_BINARY=OFF
    build_autotools "$(fetch "$SRC_LCMS2")" "$prefix" lcms2 \
        --without-tiff --without-jpeg --without-fastfloat
    local d_libarchive; d_libarchive=$(fetch "$SRC_LIBARCHIVE")
    if [[ -f $d_libarchive/meson.build ]]; then
        build_meson "$d_libarchive" "$prefix" libarchive \
            -Dzstd=disabled -Dlz4=disabled -Dnettle=disabled -Dopenssl=disabled \
            -Dexpat=disabled -Dlibb2=disabled
    else
        build_autotools "$d_libarchive" "$prefix" libarchive \
            --without-zstd --without-lz4 --without-nettle --without-ssl \
            --without-expat --without-libb2
    fi

    # 7. libplacebo（gpu-next 渲染后端；glad 子模块随 git 递归克隆）
    build_meson "$(fetch "$SRC_LIBPLACEBO" "$TAG_LIBPLACEBO")" "$prefix" libplacebo \
        -Ddemos=false -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled \
        -Dd3d11=disabled -Dopengl=enabled

    # 8. mpv libmpv 本体
    log "===== [$arch] 构建 libmpv ====="
    local bdir=$WORK/build-mpv-$arch
    rm -rf "$bdir"
    local -a setup=(meson setup "$bdir" "$MPV_SOURCE"
                    --prefix="$prefix" --buildtype=release
                    -Dlibmpv=true -Dcplayer=false -Dgpl=true
                    -Dlibbluray=enabled -Ddvdnav=enabled -Dlibarchive=enabled
                    -Dlcms2=enabled -Duchardet=enabled
                    -Dgl=enabled -Dgl-cocoa=enabled
                    -Dvulkan=disabled
                    -Dlua=disabled -Djavascript=disabled -Dcurl=disabled
                    -Dswift-build=disabled -Dmacos-cocoa-cb=disabled
                    -Dzimg=disabled -Drubberband=disabled -Djpeg=disabled
                    -Dvapoursynth=disabled -Dlibavdevice=disabled
                    -Dpdf-build=disabled
                    )
    if setup_env_is_cross; then setup+=(--cross-file "$CROSSFILE"); fi
    "${setup[@]}"
    ninja -C "$bdir" install >/dev/null

    cp "$bdir/libmpv.2.dylib" "$WORK/libmpv-$arch.dylib"
    log "[$arch] 产物: $WORK/libmpv-$arch.dylib"
}

# ---------------------------- 主流程 ----------------------------

for a in "${ARCHS[@]}"; do
    [[ $a == x86_64 ]] && ! command -v nasm >/dev/null && \
        die "x86_64 架构需要 nasm（brew install nasm）"
done

command -v meson  >/dev/null || die "缺少 meson（brew install meson）"
command -v ninja  >/dev/null || die "缺少 ninja（brew install ninja）"
command -v cmake  >/dev/null || die "缺少 cmake（brew install cmake 或 xcode）"
command -v pkg-config >/dev/null || die "缺少 pkg-config"

for a in "${ARCHS[@]}"; do
    build_arch "$a"
done

log "===== 合并产物 ====="
if [[ ${#ARCHS[@]} -eq 1 ]]; then
    cp "$WORK/libmpv-${ARCHS[0]}.dylib" "$DIST/libmpv.2.dylib"
else
    lipo -create "$WORK/libmpv-arm64.dylib" "$WORK/libmpv-x86_64.dylib" \
        -output "$DIST/libmpv.2.dylib"
fi

# 清掉指向构建目录的 rpath 并重签名（arm64 必须有签名）
while IFS= read -r rpath; do
    install_name_tool -delete_rpath "$rpath" "$DIST/libmpv.2.dylib" 2>/dev/null || true
done < <(otool -l "$DIST/libmpv.2.dylib" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}')
codesign -s - -f "$DIST/libmpv.2.dylib" >/dev/null 2>&1 || true

log "===== 校验 ====="
lipo -info "$DIST/libmpv.2.dylib"
echo "--- 动态依赖（应仅剩系统库） ---" >&2
otool -L "$DIST/libmpv.2.dylib" | tail -n +2 | sed 's/^ *//' >&2
if otool -L "$DIST/libmpv.2.dylib" | grep -qE '/opt/(homebrew|local)|/usr/local'; then
    die "产物仍依赖非系统库（brew/local 路径），不是自包含的！"
fi
ls -lh "$DIST/libmpv.2.dylib" >&2
log "完成: $DIST/libmpv.2.dylib"
