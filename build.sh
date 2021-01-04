#!/bin/sh

# Move to the directory of this shell script.
dirname=${0%/*}
[ -n "${dirname}" -a "${dirname}" != "${0}" ] && \
    cd -- "${dirname}"

# Iterate over each target we cross compile for.
for target in 'x86_64-linux' 'i386-linux' \
    'aarch64-linux' 'arm-linux' \
    'riscv64-linux' 'wasm32-wasi' \
    'x86_64-windows' 'i386-windows' \
    'x86_64-macos' 'aarch64-macos'
do
    # Print the command we are executing to build the executable.
    printf 'zig build -Drelease-fast -Dtarget=%s -Dstrip\n' "${target}" >&2

    # Determine the executable name based on target.
    case "${target}" in
        *'wasi')
            src='transpace.wasm'
            dest='transpace-wasi.wasm' ;;
        *'windows')
            src='transpace.exe'
            dest="transpace-${target}.exe" ;;
        *)
            src='transpace'
            dest="transpace-${target}" ;;
    esac
    src="./zig-cache/bin/${src}"
    dest="./build/${dest}"

    # Build the executable, moving it to the output directory on success.
    { zig build -Drelease-fast -Dtarget="${target}" -Dstrip && \
    mkdir -p build && mv "${src}" "${dest}"; } || exit
done
