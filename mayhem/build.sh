#!/usr/bin/env bash
#
# mayhem/build.sh — build lnav's fuzz harnesses (sanitized), their standalone reproducers, and the
# doctest suite (normal flags). Runs in the commit image as `mayhem` in /mayhem; offline and re-runnable.
#
# lnav is autotools. A full `make` also links the lnav binary and runs it, which no harness needs, so
# only the static libraries and objects the harnesses link are built (the same list as test/Makefile.am
# LDADD). Both trees are out of tree under mayhem/build/ (gitignored); re-running is incremental.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/mayhem/build"
HARNESSES="fuzz_logfile fuzz_data_scanner fuzz_text"

# UBSan relaxations, only these three checks: lnav's yajl callbacks are cast to a generic function-pointer
# type (-fsanitize=function), SpookyHash does unaligned 64-bit loads on purpose (alignment), and several
# string helpers pass (nullptr, 0) to memcpy (nonnull-attribute). Everything else stays halting.
RELAX="-fno-sanitize=function,alignment,nonnull-attribute"

# Everything the harnesses and tests link, relative to the build tree's src/.
SRC_OBJS="ansi-palette-json.o default-config.o xterm-palette-json.o builtin-scripts.o builtin-sh-scripts.o default-formats.o time_fmts.o lnav.events.o"
SRC_LIBS="libdiag.a libdatascanner.a formats/logfmt/liblogfmt.a fmtlib/libcppfmt.a pcrepp/libpcrepp.a yajl/libyajl.a yajlpp/libyajlpp.a base/libbase.a pugixml/libpugixml.a tailer/libtailerservice.a tailer/libtailercommon.a tailer/libtailerpp.a third-party/base64/lib/libbase64.a third-party/date/src/libdatepp.a third-party/notcurses/src/lib/liblnavnotcurses.a third-party/scnlib/src/libscnlib.a"

[ -x "$SRC/configure" ] || ./autogen.sh >/dev/null

# build_tree <dir> <cflags> <ldflags>: configure (once) and build the libs/objs above.
build_tree() {
  local dir="$1" cflags="$2" ldflags="$3"
  mkdir -p "$dir"
  if [ ! -f "$dir/Makefile" ]; then
    (cd "$dir" && ASAN_OPTIONS=detect_leaks=0 "$SRC/configure" --without-cargo CC="$CC" CXX="$CXX" \
        CFLAGS="$cflags" CXXFLAGS="$cflags" LDFLAGS="$ldflags") >"$dir/configure.log" 2>&1 \
      || { tail -40 "$dir/configure.log"; exit 1; }
  fi
  export ASAN_OPTIONS=detect_leaks=0
  make -C "$dir/tools" -j"$MAYHEM_JOBS" >/dev/null
  local built
  built=$(make -C "$dir/src" -s -f Makefile -f - __built <<<'__built: ; @echo $(LNAV_BUILT_FILES)')
  make -C "$dir/src" -j"$MAYHEM_JOBS" $built >/dev/null
  local d
  for d in $(for l in $SRC_LIBS; do dirname "$l"; done | sort -u | grep -v '^\.$'); do
    make -C "$dir/src/$d" -j"$MAYHEM_JOBS" >/dev/null
  done
  make -C "$dir/src" -j"$MAYHEM_JOBS" $SRC_OBJS libdiag.a libdatascanner.a >/dev/null
}

# 1) Sanitized tree: the project itself with $SANITIZER_FLAGS / $DEBUG_FLAGS and SanCov, for the harnesses.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $RELAX -O1"
build_tree "$B/fuzz" "$FUZZ_CFLAGS" "$SANITIZER_FLAGS"

# 2) Harnesses: fuzzer binary and standalone reproducer, linked against the sanitized libs.
cd "$B/fuzz/test"
INCL=$(make -s -f Makefile -f - __flags <<<'__flags: ; @echo $(DEFS) $(DEFAULT_INCLUDES) $(INCLUDES) $(AM_CPPFLAGS) $(CPPFLAGS)')
SYSLIBS="$(make -s -f Makefile -f - __libs <<<'__libs: ; @echo $(LIBS) $(LIBARCHIVE_LIBS) $(SQLITE3_LIBS) $(LIBCURL) -lncurses') -lunistring"
S="$B/fuzz/src"
LINK_OBJS=""; for o in $SRC_OBJS; do LINK_OBJS="$LINK_OBJS $S/$o"; done
LINK_LIBS=""; for l in $SRC_LIBS; do LINK_LIBS="$LINK_LIBS $S/$l"; done
CXXF="-std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS $RELAX -O1 -fsanitize=fuzzer-no-link $INCL"

$CXX $CXXF -c "$SRC/test/test_stubs.cc" -o "$B/fuzz/test_stubs.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c -x c++ "$SRC/mayhem/lsan_off.cc" -o "$B/fuzz/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/fuzz/standalone_main.o"
for h in $HARNESSES; do
  $CXX $CXXF -c "$SRC/mayhem/$h.cc" -o "$B/fuzz/$h.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/fuzz/$h.o" "$B/fuzz/lsan_off.o" "$B/fuzz/test_stubs.o" \
      -lz $LINK_OBJS $LINK_LIBS $SYSLIBS -o "/mayhem/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$B/fuzz/$h.o" "$B/fuzz/lsan_off.o" "$B/fuzz/test_stubs.o" "$B/fuzz/standalone_main.o" \
      -lz $LINK_OBJS $LINK_LIBS $SYSLIBS -o "/mayhem/$h-standalone"
done

# 3) Test suite with the project's normal flags (no sanitizers), run by test.sh.
cd "$SRC"
build_tree "$B/test" "-O0 $COVERAGE_FLAGS" "$COVERAGE_FLAGS"
make -C "$B/test/test" -j"$MAYHEM_JOBS" test_reltime test_date_time_scanner lnav_doctests >/dev/null
