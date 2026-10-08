cmake_minimum_required(VERSION 3.22.1)
project(romgi_pkg2zip)

# pkg2zip (https://github.com/mmozeiko/pkg2zip, public domain/Unlicense) is
# vendored into the pkg2zip/ subdirectory below, at upstream commit
# 9222c4e00235dfe7914e9db0cc352da07e63d9f9 - only the files actually
# compiled below (see PKG2ZIP_SOURCES), not the whole upstream repo (its
# build.cmd/makefile/README/rif2zrif.py/zrif2rif.py aren't part of our
# build). Previously pulled in as a git submodule; vendored directly
# instead so the source is self-contained and reviewable in a single diff
# (relevant if this ever needs to be submitted upstream) without requiring
# a submodule checkout step.
#
# One small local patch on top of upstream, in pkg2zip.c's license
# argument handling: accept a raw, already-decoded .rif file directly (not
# just a zRIF string). We sometimes already have the decoded rif on disk
# (see lib/services/zrif_codec.dart) and would otherwise have to re-encode
# it back into a zRIF string just for pkg2zip to decode it again.
#
# Its main() already implements exactly the operation we need - "decrypt
# file.pkg [zRIF] -> zip" - as a CLI tool, so rather than reverse-engineer
# its internals into a library API it's compiled as-is into a native
# executable and invoked as a subprocess from Dart
# (lib/services/vita_decrypt_service.dart), the same way the upstream
# project intends it to be used. This is the "ship a prebuilt binary,
# invoke via subprocess" approach: Android allows this as long as the
# binary lives under the app's own nativeLibraryDir, which is why the
# build step below packages it into src/main/jniLibs/<abi>/libpkg2zip.so -
# it's a real ELF executable, just named and placed the way Android's APK
# packaging expects native code to live.
set(PKG2ZIP_DIR ${CMAKE_SOURCE_DIR}/pkg2zip)

set(PKG2ZIP_SOURCES
    ${PKG2ZIP_DIR}/pkg2zip.c
    ${PKG2ZIP_DIR}/pkg2zip_aes.c
    ${PKG2ZIP_DIR}/pkg2zip_crc32.c
    ${PKG2ZIP_DIR}/pkg2zip_out.c
    ${PKG2ZIP_DIR}/pkg2zip_psp.c
    ${PKG2ZIP_DIR}/pkg2zip_sys.c
    ${PKG2ZIP_DIR}/pkg2zip_zip.c
    ${PKG2ZIP_DIR}/pkg2zip_zrif.c
    ${PKG2ZIP_DIR}/miniz_tdef.c
    ${PKG2ZIP_DIR}/puff.c
)

# pkg2zip_aes.c/pkg2zip_crc32.c already runtime-dispatch to these x86-only
# SSE/AES-NI/PCLMUL accelerated paths (falling back to portable C otherwise,
# see PLATFORM_SUPPORTS_AESNI), but the _x86.c translation units themselves
# use x86 intrinsic headers unconditionally with no arch guard — they must
# be excluded from the arm64-v8a build entirely rather than merely unused,
# or clang fails to compile the intrinsic headers for that target.
if(ANDROID_ABI MATCHES "^x86")
    list(APPEND PKG2ZIP_SOURCES
        ${PKG2ZIP_DIR}/pkg2zip_aes_x86.c
        ${PKG2ZIP_DIR}/pkg2zip_crc32_x86.c
    )
    set_source_files_properties(${PKG2ZIP_DIR}/pkg2zip_aes_x86.c
        PROPERTIES COMPILE_OPTIONS "-maes;-mssse3")
    set_source_files_properties(${PKG2ZIP_DIR}/pkg2zip_crc32_x86.c
        PROPERTIES COMPILE_OPTIONS "-mpclmul;-msse4")
endif()

add_executable(pkg2zip_bin ${PKG2ZIP_SOURCES})

target_include_directories(pkg2zip_bin PRIVATE ${PKG2ZIP_DIR})

set(JNILIBS_ABI_DIR ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})

add_custom_command(TARGET pkg2zip_bin POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${JNILIBS_ABI_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:pkg2zip_bin> ${JNILIBS_ABI_DIR}/libpkg2zip.so
)
