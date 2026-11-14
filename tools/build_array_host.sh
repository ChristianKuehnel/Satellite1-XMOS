#!/usr/bin/env bash
# tools/build_array_host.sh
# Builds the host-compiled array frontend unit tests.
# Usage: bash tools/build_array_host.sh [--clean]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build-host/array"

if [[ "${1:-}" == "--clean" ]]; then
    echo "Cleaning build directory..."
    rm -rf "${BUILD_DIR}"
fi

# Ensure cmake is available
if ! command -v cmake &>/dev/null && [[ -f "${REPO_ROOT}/.venv/bin/cmake" ]]; then
    export PATH="${REPO_ROOT}/.venv/bin:${PATH}"
fi

# Ensure lib_xcore_math source is present
if [[ ! -d "${REPO_ROOT}/modules/core/modules/xcore_math/lib_xcore_math/lib_xcore_math" ]]; then
    echo "Error: modules/core submodule not initialized."
    echo "Run: git submodule update --init modules/core"
    exit 1
fi

echo "Configuring..."
cmake -S "${REPO_ROOT}/tests/test_array_host" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release

echo "Building..."
cmake --build "${BUILD_DIR}" -j"$(nproc)"

echo
echo "Build complete. Running tests..."
ctest --test-dir "${BUILD_DIR}" --output-on-failure
