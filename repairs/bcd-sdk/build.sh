#!/usr/bin/env bash
# Build the omitted Wine module, without rebuilding LC or the iOS host.
set -euo pipefail
R="$PWD"
WINE_REV=a1049ce9cf37f6cf3c771dead31dcbe3b4e4a0c6
mkdir -p work out
git init work/wine
git -C work/wine remote add origin https://github.com/thebcd69/bcd-wine.git
git -C work/wine fetch --depth 1 origin "$WINE_REV"
git -C work/wine checkout "$WINE_REV"
curl --fail --location --retry 3 -o work/llvm-mingw.tar.xz https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/llvm-mingw-20260421-ucrt-ubuntu-22.04-x86_64.tar.xz
tar -xJf work/llvm-mingw.tar.xz -C work
export PATH="$R/work/llvm-mingw-20260421-ucrt-ubuntu-22.04-x86_64/bin:$PATH"
python3 repairs/bcd-sdk/prepare_wine.py work/wine
mkdir -p work/wine/build-native work/wine/build-arm64ec
(
  cd work/wine/build-native
  ../configure --enable-win64 --without-x --without-freetype --without-gnutls --disable-tests > "$R/out/native-configure.log" 2>&1
  make -j4 __tools__ include > "$R/out/native-make.log" 2>&1
)
(
  cd work/wine/build-arm64ec
  ../configure --enable-archs=arm64ec --with-wine-tools="$R/work/wine/build-native" --without-x --without-freetype --without-gnutls --disable-tests > "$R/out/arm64ec-configure.log" 2>&1
  make -j4 dlls/ntdsapi/arm64ec-windows/ntdsapi.dll > "$R/out/arm64ec-make.log" 2>&1
)
cp work/wine/build-arm64ec/dlls/ntdsapi/arm64ec-windows/ntdsapi.dll out/ntdsapi.dll
arm64ec-w64-mingw32-strip --strip-debug out/ntdsapi.dll
curl --fail --location --retry 3 -o work/BCD-original.ipa https://github.com/thebcd69/bcd-games/releases/download/v0.1.580/BCD.ipa
python3 repairs/bcd-sdk/package.py work/BCD-original.ipa out/ntdsapi.dll out
# Full, pinned corresponding Wine source, including the configure-only changes.
git -C work/wine archive --format=tar HEAD | xz -T2 > out/bcd-wine-a1049ce-source.tar.xz
git -C work/wine diff > out/configure-only.patch
cp repairs/bcd-sdk/{README.md,build.sh,prepare_wine.py,package.py} out/
cp work/wine/COPYING.LIB out/
sha256sum out/ntdsapi.dll out/*.ipa out/*source.tar.xz > out/SHA256SUMS
