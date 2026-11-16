# Host test harness for the fwk_voice single-threaded audio pipeline.
#
# Builds the local main.c together with the (unmodified) pipeline.c from the
# fwk_voice submodule (modules/voice/examples/pipeline/src/pipeline.c),
# linking the fwk_voice interface libraries. This provides a host buildable
# equivalent of the bare-metal-only examples/pipeline app, used by
# tests/test_dsp_host.
#
# Configure with: cmake -B build-host -S tools/dsp_host

cmake_minimum_required(VERSION 3.21)

## CXX is required: lib_vnr contains C++ inference sources and a generated
## C++ TFLite model (with C-only, CMake silently drops them and linking fails)
project(fwk_voice_dsp_host_harness C CXX)

set(VOICE_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../modules/voice)

if(NOT EXISTS ${VOICE_ROOT}/CMakeLists.txt)
    message(FATAL_ERROR "modules/voice not initialized.\nRun: git submodule update --init modules/voice")
endif()

## Fetch lib_xcore_math.
## Pinned to v2.4.1: the fwk_voice v0.9.0 submodule (modules/voice) still
## uses the v2.x float_s32 conversion API (e.g. float_s32_to_float in
## lib_ic/src/ic_low_level.c), which was renamed in lib_xcore_math v3.0.0.
## Note: the fwk_voice top-level CMakeLists.txt fetches 'develop', which is
## currently the v3.x API and does not compile the pinned submodule version.
set(XCORE_MATH_PATH ${CMAKE_BINARY_DIR}/fwk_voice_deps)
include(FetchContent)
FetchContent_Declare(
    xcore_math
    GIT_REPOSITORY https://github.com/xmos/lib_xcore_math.git
    GIT_TAG        c15fcac74260ae733550ed570ca87262a5416d7b
    GIT_SHALLOW    FALSE
    SOURCE_DIR     ${XCORE_MATH_PATH}/lib_xcore_math
)
FetchContent_Populate(xcore_math)
add_subdirectory(${XCORE_MATH_PATH}/lib_xcore_math/lib_xcore_math ${XCORE_MATH_PATH}/build)

## Host build definition (the fwk_voice top-level CMakeLists defines X86_BUILD
## for all non-XCORE systems)
add_compile_definitions(X86_BUILD=1)

## fwk_voice interface libraries (read-only, from the submodule)
add_subdirectory(${VOICE_ROOT}/modules ${CMAKE_BINARY_DIR}/fwk_voice_modules)

## Executable: local main + submodule pipeline.c (compiled in place, not modified)
add_executable(dsp_host_pipeline
    main.c
    ${VOICE_ROOT}/examples/pipeline/src/pipeline.c
)

target_include_directories(dsp_host_pipeline PRIVATE ${VOICE_ROOT}/examples/pipeline/src)

target_link_libraries(dsp_host_pipeline PRIVATE
    fwk_voice::aec
    fwk_voice::adec
    fwk_voice::ns
    fwk_voice::agc
    fwk_voice::ic
    fwk_voice::vnr
    fwk_voice::stage1
    m
)

set_target_properties(dsp_host_pipeline PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
