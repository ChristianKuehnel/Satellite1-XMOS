#!/bin/bash
set -e

# help text
help()
{
   echo "XCORE firmware builder script"
   echo
   echo "Syntax: build_firmware.sh [-h] <firmware_list.txt>"
   echo
   echo "firmware_list.txt format:"
   echo "   name app_target run_data_partition_target BOARD toolchain"
   echo
   echo "Lines starting with '#' and blank lines are ignored."
   echo "Entries sharing a board reuse one CMake build directory"
   echo "(build_<BOARD>), configured on the first entry and then built"
   echo "incrementally. Delete the directory to force a clean reconfigure."
   echo
   echo "options:"
   echo "h     Print this Help."
}

# flag arguments
while getopts h option
do
    case "${option}" in
        h) help
           exit;;
    esac
done

# get input list file
INPUT_LIST=${@:$OPTIND:1}
if [ ! -f "$INPUT_LIST" ]; then
    echo "ERROR: $INPUT_LIST does not exist"
    exit
fi

XCORE_VOICE_ROOT=`git rev-parse --show-toplevel`

source ${XCORE_VOICE_ROOT}/tools/ci/helper_functions.sh
export_ci_build_vars
setup_python_env "${XCORE_VOICE_ROOT}" 

# setup distribution folder
DIST_DIR=${XCORE_VOICE_ROOT}/dist
DIST_HOST_DIR=${XCORE_VOICE_ROOT}/dist_host
mkdir -p ${DIST_DIR}

if [ -d "${DIST_HOST_DIR}" ]; then
    # add DIST_HOST_DIR to path.
    #   This is used in CI for fatfs_mkimage
    PATH="${DIST_HOST_DIR}":$PATH
    find ${DIST_HOST_DIR} -type f -exec chmod a+x {} +
fi

readarray examples < ${INPUT_LIST}

# perform builds
for ((i = 0; i < ${#examples[@]}; i += 1)); do
    line="${examples[i]}"
    # skip blank lines and comments
    [[ "${line//[[:space:]]/}" == "" || "${line}" =~ ^[[:space:]]*# ]] && continue
    read -ra FIELDS <<< ${line}
    name="${FIELDS[0]}"
    app_target="${FIELDS[1]}"
    run_data_partition_target="${FIELDS[2]}"
    board="${FIELDS[3]}"
    toolchain_file="${XCORE_VOICE_ROOT}/${FIELDS[4]}"
    path="${XCORE_VOICE_ROOT}"
    build_dir="${path}/build_${board}"
    echo '******************************************************'
    echo '* Building' ${name}, ${app_target} 'for' ${board}
    echo '******************************************************'

    # Configure once per board; subsequent entries reuse the build directory.
    if [ ! -f "${build_dir}/CMakeCache.txt" ]; then
        (cd ${path}; rm -rf build_${board})
        (cd ${path}; mkdir -p build_${board})
        (cd ${build_dir}; log_errors cmake ../ -G "$CI_CMAKE_GENERATOR" -DCMAKE_TOOLCHAIN_FILE=${toolchain_file} -DBOARD=${board} -DENABLE_ALL_FFVA_PIPELINES=1 -DALLOW_DIRTY_VERSIONING=ON)
    fi
    (cd ${build_dir}; log_errors $CI_BUILD_TOOL ${app_target} $CI_BUILD_TOOL_ARGS)
    (cd ${build_dir}; cp ${app_target}.xe ${DIST_DIR})
    
    if [ "$run_data_partition_target" = "Yes" ]; then
        echo '======================================================'
        echo '= Making data partition for' ${app_target}
        echo '======================================================'
        (cd ${build_dir}; log_errors $CI_BUILD_TOOL make_data_partition_${app_target} $CI_BUILD_TOOL_ARGS)
        (cd ${build_dir}; cp ${app_target}_data_partition.bin ${DIST_DIR})
    fi
    
    (cd ${build_dir}; log_errors $CI_BUILD_TOOL create_flash_img_${app_target} $CI_BUILD_TOOL_ARGS)
    (cd ${build_dir}; cp ${app_target}.factory.bin ${app_target}.factory.md5 ${DIST_DIR})
    (cd ${build_dir}; log_errors $CI_BUILD_TOOL create_upgrade_img_${app_target} $CI_BUILD_TOOL_ARGS)
    (cd ${build_dir}; cp ${app_target}.upgrade.bin ${app_target}.upgrade.md5 ${DIST_DIR})
    
    echo '******************************************************'
    echo '* Add extra files'
    echo '******************************************************'
    cd ${path}; cp LICENSE.md ${DIST_DIR}
    cd ${path}; cp README.md ${DIST_DIR}
done
