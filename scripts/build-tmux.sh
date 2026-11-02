#!/bin/bash
# Builds the tmux Side A ships at Contents/Helpers/tmux: universal (arm64 + x86_64), with libevent,
# ncurses, utf8proc (character widths) and jemalloc (tmux 3.7c needs it on macOS, issue 5385) linked in statically, so hosted sessions never need Homebrew and every
# client runs the same version as the server. Sources are pinned by SHA-256; each checksum was
# confirmed against an independent source (Homebrew's formula, or GitHub's published asset digest).
# Output: .build/tmux/{tmux,terminfo/,licenses/}. Reruns are free while the pins and this script are unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."

TMUX_VERSION=3.7c
SOURCES=(
  "tmux-3.7c.tar.gz https://github.com/tmux/tmux/releases/download/3.7c/tmux-3.7c.tar.gz 7c60cae9a0e25288e2e24750aafc9e8800fc7fd4555e447e1b29ee4201cfb3bf"
  "libevent-2.1.13-stable.tar.gz https://github.com/libevent/libevent/releases/download/release-2.1.13-stable/libevent-2.1.13-stable.tar.gz f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c"
  "ncurses-6.6.tar.gz https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz 355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11"
  "utf8proc-2.12.0.tar.gz https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v2.12.0.tar.gz f564011d38b2888d583d510b08e69ffa15aa117155db1b9b49ef1dfe1fa25111"
  "jemalloc-5.4.0.tar.bz2 https://github.com/jemalloc/jemalloc/releases/download/5.4.0/jemalloc-5.4.0.tar.bz2 200776fac271093e7c2f21edd6d62657ecd2be578d9328633f2a86bfa6ef4f1d"
)
MIN_MACOS=14.0
out="$PWD/.build/tmux"
cache="$PWD/.build/tmux-src"
stamp="$out/.stamp"
pins="$(printf '%s\n' "${SOURCES[@]}" "$MIN_MACOS"; shasum -a 256 < "$0")"
if [[ -x "$out/tmux" && -f "$stamp" && "$(cat "$stamp")" == "$pins" ]]; then echo "$out/tmux"; exit 0; fi

mkdir -p "$cache"
for entry in "${SOURCES[@]}"; do
  read -r file url sum <<<"$entry"
  if [[ ! -f "$cache/$file" ]] || ! echo "$sum  $cache/$file" | shasum -a 256 -c --status; then
    curl -fsSL --retry 3 -o "$cache/$file.part" "$url"
    mv "$cache/$file.part" "$cache/$file"
  fi
  echo "$sum  $cache/$file" | shasum -a 256 -c --status || { echo "Checksum mismatch: $file" >&2; exit 1; }
done

rm -rf "$out"
mkdir -p "$out/licenses"
# Nothing from Homebrew or the environment may leak into the link.
unset CPATH LIBRARY_PATH C_INCLUDE_PATH PKG_CONFIG_PATH
export PKG_CONFIG=/usr/bin/false
jobs="$(sysctl -n hw.ncpu)"

for arch in arm64 x86_64; do
  work="$out/work-$arch" prefix="$out/prefix-$arch"
  mkdir -p "$work" "$prefix/include" "$prefix/lib"
  host="$([[ $arch == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)"
  export CC="clang -arch $arch -mmacosx-version-min=$MIN_MACOS" CFLAGS="-O2" BUILD_CC=clang
  for entry in "${SOURCES[@]}"; do read -r file _ _ <<<"$entry"; tar -xf "$cache/$file" -C "$work"; done

  (cd "$work/utf8proc-2.12.0" && make -s CC="$CC" libutf8proc.a >/dev/null && cp utf8proc.h "$prefix/include/" && cp libutf8proc.a "$prefix/lib/")
  # Unprefixed, as tmux calls mallctl (and as Homebrew builds it); the page size is set, not probed,
  # because a cross-compiled probe can't run and 4 KiB pages fail on Apple silicon's 16 KiB. tmux
  # loads the whole archive: nothing references zone.o, whose constructor makes jemalloc the default
  # zone, and without it libc's own allocations reach jemalloc's free and crash.
  (cd "$work/jemalloc-5.4.0" && ./configure -q --host="$host" --prefix="$prefix" --with-jemalloc-prefix= \
     --with-lg-page="$([[ $arch == arm64 ]] && echo 14 || echo 12)" --disable-cxx --disable-stats --disable-doc \
     && make -s -j"$jobs" build_lib_static >/dev/null && make -s install_lib_static install_include >/dev/null)
  (cd "$work/libevent-2.1.13-stable" && ./configure -q --host="$host" --prefix="$prefix" --disable-shared --enable-static \
     --disable-openssl --disable-samples --disable-libevent-regress --disable-debug-mode --disable-dependency-tracking \
     && make -s -j"$jobs" >/dev/null && make -s install >/dev/null)
  # The library reads terminal descriptions from the system and from TERMINFO/TERMINFO_DIRS; no database is installed.
  (cd "$work/ncurses-6.6" && ./configure -q --host="$host" --prefix="$prefix" --without-shared --with-normal --without-debug \
     --without-cxx --without-cxx-binding --without-ada --without-manpages --without-progs --without-tests --enable-widec \
     --disable-db-install --with-default-terminfo-dir=/usr/share/terminfo --with-terminfo-dirs=/usr/share/terminfo \
     && make -s -j"$jobs" libs >/dev/null && make -s install.libs install.includes >/dev/null)
  (cd "$work/tmux-$TMUX_VERSION" && ./configure -q --host="$host" --prefix=/usr/local --enable-utf8proc --disable-dependency-tracking \
     LIBEVENT_CORE_CFLAGS="-I$prefix/include" LIBEVENT_CORE_LIBS="$prefix/lib/libevent_core.a" \
     LIBTINFOW_CFLAGS="-I$prefix/include/ncursesw -I$prefix/include" LIBTINFOW_LIBS="$prefix/lib/libncursesw.a" \
     LIBUTF8PROC_CFLAGS="-I$prefix/include -DUTF8PROC_STATIC" LIBUTF8PROC_LIBS="$prefix/lib/libutf8proc.a" \
     JEMALLOC_CFLAGS="-I$prefix/include" JEMALLOC_LIBS="-Wl,-force_load,$prefix/lib/libjemalloc.a" \
     CPPFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib" \
     && make -s -j"$jobs" >/dev/null)
  binary="$work/tmux-$TMUX_VERSION/tmux"
  # Only system libraries may stay dynamic.
  if otool -L "$binary" | tail -n +2 | grep -v -E '^\s+/usr/lib/|^\s+/System/Library/' >&2; then
    echo "tmux links a non-system library ($arch)" >&2; exit 1
  fi
  cp "$binary" "$out/tmux-$arch"
done

lipo -create "$out/tmux-arm64" "$out/tmux-x86_64" -output "$out/tmux"
work="$out/work-arm64"
# tmux-256color for the panes, from ncurses' own source: older macOS releases don't ship it.
mkdir -p "$out/terminfo"
/usr/bin/tic -x -o "$out/terminfo" -e tmux,tmux-256color "$work/ncurses-6.6/misc/terminfo.src"
cp "$work/tmux-$TMUX_VERSION/COPYING" "$out/licenses/tmux.txt"
cp "$work/libevent-2.1.13-stable/LICENSE" "$out/licenses/libevent.txt"
cp "$work/ncurses-6.6/COPYING" "$out/licenses/ncurses.txt"
cp "$work/utf8proc-2.12.0/LICENSE.md" "$out/licenses/utf8proc.txt"
cp "$work/jemalloc-5.4.0/COPYING" "$out/licenses/jemalloc.txt"
rm -rf "$out"/work-* "$out"/prefix-* "$out"/tmux-arm64 "$out"/tmux-x86_64
printf '%s' "$pins" > "$stamp"
echo "$out/tmux"
