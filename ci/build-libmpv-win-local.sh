#!/usr/bin/env bash
# 在本机 Docker 中复刻 .github/workflows/build-libmpv-win.yml 的完整构建流程，
# 产出 mpv-dev-x86_64 包（libmpv-2.dll + libmpv.dll.a + 头文件），输出到本仓库 dist/。
#
# 与 CI 的对应关系：
#   actions/checkout(mpv 本仓库)   -> 只读挂载本仓库到容器 /work/mpv
#   actions/checkout(winbuild)     -> 容器内 clone shinchiro/mpv-winbuild-cmake
#   actions/cache(clang_root 等)   -> 三个 named volume，容器外持久保留（增量构建）
#   upload-artifact                -> 挂载 dist/ 收集产物
#   configure/build/打包/清理步骤  -> 与 workflow 逐条一致
#
# 注意：
#   - 镜像是 linux/amd64，Apple Silicon Mac 经 Rosetta/QEMU 模拟运行。首次
#     全量构建（LLVM+工具链+全部依赖）CI 上约 1-2 小时，本机模拟可能要数小时；
#     建议在 Docker Desktop 设置中开启 "Use Rosetta for x86_64/amd64 emulation"
#     并把内存调到 >= 12GB（LLVM 构建与 ThinLTO 链接吃内存），之后命中 volume
#     缓存，每轮只重建 mpv 与变动依赖。
#   - 如需代理访问 GitHub，在 docker run 里加：
#       -e HTTPS_PROXY=http://host.docker.internal:端口 -e HTTP_PROXY=...

set -euo pipefail

IMAGE=ghcr.io/shinchiro/archlinux:latest
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$REPO_ROOT/dist"
rm -f "$REPO_ROOT"/dist/*.7z "$REPO_ROOT"/dist/*.dll 2>/dev/null || true

docker run --rm -i --platform linux/amd64 \
  -v "$REPO_ROOT":/work/mpv:ro \
  -v "$REPO_ROOT/dist":/work/release_x86_64 \
  -v libmpv-win-clang_root:/work/clang_root \
  -v libmpv-win-src_packages:/work/src_packages \
  -v libmpv-win-build_x86_64:/work/build_x86_64 \
  "$IMAGE" bash -s <<'BUILD_SCRIPT'
set -euxo pipefail
cd /work

git config --global user.name "local-build"
git config --global user.email "local@build"
# 挂载进来的本仓库属主是宿主机用户，容器内 root 访问需声明信任
git config --global --add safe.directory /work/mpv

# Checkout mpv-winbuild-cmake（对应 workflow 的 checkout 步骤）
rm -rf mpv-winbuild-cmake
git clone --depth 1 https://github.com/shinchiro/mpv-winbuild-cmake mpv-winbuild-cmake

# Point mpv package source to this repo（与 workflow 相同的三处 sed）
sed -i 's|GIT_REPOSITORY https://github.com/mpv-player/mpv.git|GIT_REPOSITORY /work/mpv|' \
  mpv-winbuild-cmake/packages/mpv.cmake
sed -i '/GIT_CLONE_FLAGS/d' mpv-winbuild-cmake/packages/mpv.cmake
sed -i 's|GIT_REPOSITORY https://github.com/haasn/libplacebo.git|GIT_REPOSITORY https://github.com/haasn/libplacebo.git\n    GIT_TAG v7.351.0|' \
  mpv-winbuild-cmake/packages/libplacebo.cmake
grep -n "GIT_REPOSITORY\|GIT_CLONE_FLAGS\|GIT_TAG" \
  mpv-winbuild-cmake/packages/mpv.cmake mpv-winbuild-cmake/packages/libplacebo.cmake || true
# mpv 源码远端是本地路径，force-update 的 filtered fetch 不可靠，
# 每次删旧克隆、按挂载进来的当前提交重新克隆
rm -rf src_packages/mpv

# Configuring CMake & Downloading source（命令行与 workflow 完全一致）
cmake -DTARGET_ARCH=x86_64-w64-mingw32 -DCOMPILER_TOOLCHAIN=clang \
  -DCMAKE_INSTALL_PREFIX=/work/clang_root \
  -DMINGW_INSTALL_PREFIX=/work/build_x86_64/x86_64-w64-mingw32 \
  -DSINGLE_SOURCE_LOCATION=/work/src_packages \
  -DRUSTUP_LOCATION=/work/clang_root/install_rustup \
  -DENABLE_CCACHE=ON -DCLANG_PACKAGES_LTO=ON \
  -G Ninja --fresh -B build_x86_64 -S /work/mpv-winbuild-cmake
ninja -C build_x86_64 download || true

# Building mpv + Packaging mpv-dev
ninja -C build_x86_64 update
# libplacebo v7.351.0 的 utils_gen.py 与镜像 Python 3.14 不兼容，构建前打一行
# 补丁（等价于上游 haasn/libplacebo@12509c0f1e；必须在 update 之后，force-update
# 会 git reset --hard 还原源码树，每次运行重打是幂等的；详见 workflow 内注释）
sed -i 's|VkXML(ET.parse(xmlfile))|VkXML(ET.parse(xmlfile).getroot())|' \
  src_packages/libplacebo/src/vulkan/utils_gen.py
grep -n 'registry = VkXML' src_packages/libplacebo/src/vulkan/utils_gen.py
# 从零自举先建 LLVM 再建其余工具链：包 configure 用的
# x86_64-w64-mingw32-gcc 包装脚本背后是 clang_root/bin/clang，
# 不先建好 llvm 的话 zlib 等最早的包 configure 会全部失败；
# volume 缓存命中时这两条是秒级 no-op
ninja -C build_x86_64 llvm
ninja -C build_x86_64 llvm-clang
ninja -C build_x86_64 mpv
ninja -C build_x86_64 mpv-packaging

mv build_x86_64/mpv-dev-*.7z release_x86_64/
# libmpv-2.dll 运行时依赖 vulkan-1.dll，一并收集（存在才收）
find build_x86_64 -name 'vulkan-1.dll' -exec cp {} release_x86_64/ \; 2>/dev/null || true
ls -lh release_x86_64/

# Cleaning（与 CI 相同：mpv 构建产物全删，下次全量重建；rust 缓存瘦身）
rm -rf build_x86_64/mpv*
ninja -C build_x86_64 cargo-clean || true
BUILD_SCRIPT
