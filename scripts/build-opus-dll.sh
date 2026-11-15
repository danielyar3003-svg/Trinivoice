#!/usr/bin/env bash
# Сборка client/moonloader/lib/opus.dll (32-бит Windows) из официальных исходников Opus.
# Нужно: git, cmake, mingw-w64 (apt install mingw-w64 cmake).
set -euo pipefail
# фиксированное время сборки: одинаковые исходники дают побайтно одинаковую DLL
export SOURCE_DATE_EPOCH=1700000000
cd "$(dirname "$0")/.."
TAG=v1.5.2
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
git clone -q --depth 1 --branch "$TAG" https://github.com/xiph/opus.git "$W/src"
cat > "$W/tc.cmake" <<TC
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR i686)
set(CMAKE_C_COMPILER i686-w64-mingw32-gcc)
set(CMAKE_RC_COMPILER i686-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH /usr/i686-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
TC
# без нейросетевых расширений (DRED/OSCE/Deep PLC): им нужны модели из сети;
# ускорения SSE/AVX2 включаются только после проверки процессора во время работы
cmake -S "$W/src" -B "$W/build" -DCMAKE_TOOLCHAIN_FILE="$W/tc.cmake" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
  -DOPUS_DRED=OFF -DOPUS_OSCE=OFF -DOPUS_DEEP_PLC=OFF -DCMAKE_C_FLAGS="-O2 -ffile-prefix-map=$W=/opus" \
  -DCMAKE_SHARED_LINKER_FLAGS="-static-libgcc -static -Wl,--no-insert-timestamp" >/dev/null
cmake --build "$W/build" -j"$(nproc)" >/dev/null
i686-w64-mingw32-strip -o client/moonloader/lib/opus.dll "$W/build/libopus.dll"
i686-w64-mingw32-objdump -p client/moonloader/lib/opus.dll | grep "DLL Name"
sha256sum client/moonloader/lib/opus.dll
