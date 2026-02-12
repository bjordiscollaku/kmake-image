#!/bin/bash

###############################################################################
# make_fitimage.sh - FIT image packaging script for Qualcomm Linux development
#
# Usage:
#   ./make_fitimage.sh --metadata <metadata_dts> --its <fitimage_its> [--kobj <kernel_build_artifacts>] [--output <output_dir>]
#
# Options:
#   --metadata  Path to metadata DTS file (mandatory)
#   --its       Path to FIT image ITS file (mandatory)
#   --kobj      Path to kernel build artifacts directory (default: ../kobj)
#   --kernel-deb Path to kernel .deb package (Alternative to --kobj)
#   --output    Output directory for generated FIT image (default: ../images)
#   --help      Show help message
#
# Description:
#   This script generates a FIT image using Qualcomm metadata and ITS files.
#   It compiles the metadata DTS to DTB, creates the FIT image using mkimage,
#   and packages the final image using generate_boot_bins.sh
###############################################################################

set -e

# Get the directory where this script resides to find helper scripts
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Default paths
KERNEL_BUILD_ARTIFACTS="../kobj"
OUTPUT_DIR="../images"
METADATA_DTS_PATH="../artifacts/qcom-dtb-metadata/qcom-metadata.dts"
FIT_IMAGE_ITS_PATH="../artifacts/qcom-dtb-metadata/qcom-fitimage.its"
KERNEL_DEB=""

# Help message
function show_help() {
    cat <<EOF
Usage:
  ./make_fitimage.sh [OPTIONS]

Options:
  --metadata <path>    Path to metadata DTS file (default: $METADATA_DTS_PATH)
  --its <path>         Path to FIT image ITS file (default: $FIT_IMAGE_ITS_PATH)
  --kobj <path>        Path to kernel build artifacts directory (default: $KERNEL_BUILD_ARTIFACTS)
  --kernel-deb <path>  Path to kernel .deb package (Alternative to --kobj)
  --output <path>      Output directory for generated FIT image (default: $OUTPUT_DIR)
  --help               Show this help message and exit

Description:
  This script generates a FIT image using Qualcomm metadata and ITS files.
  It compiles the metadata DTS to DTB, creates the FIT image using mkimage,
  and packages the final image using generate_boot_bins.sh.

Note:
  You can obtain the metadata DTS and FIT image ITS files from:
  https://github.com/qualcomm-linux/qcom-dtb-metadata
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kobj) KERNEL_BUILD_ARTIFACTS="$2"; shift 2 ;;
        --metadata) METADATA_DTS_PATH="$2"; shift 2 ;;
        --its) FIT_IMAGE_ITS_PATH="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --kernel-deb) KERNEL_DEB="$2"; shift 2 ;;
        --help) show_help; exit 0 ;;
        *) echo "Unknown option: $1"; show_help ; exit 1 ;;
    esac
done

# --- NEW FUNCTION: process_kernel_deb ---
# Extracts a .deb and reconstructs a 'kobj' like structure so ITS files work unchanged
function process_kernel_deb() {
    local DEB_PATH="$1"
    local WORK_DIR
    WORK_DIR=$(mktemp -d)
    
    # Send logs to stderr (>&2) so they are not captured by the variable assignment
    echo "Processing .deb package: $DEB_PATH" >&2
    
    # 1. Extract the deb
    if ! command -v dpkg-deb &> /dev/null; then
        echo "Error: dpkg-deb not found. Cannot extract .deb files." >&2
        rm -rf "$WORK_DIR"
        exit 1
    fi
    # Extract to 'extracted' subdir to keep things clean
    dpkg-deb -x "$DEB_PATH" "$WORK_DIR/extracted"

    # 2. Find the DTB Directory
    # Strategy: Look in typical Ubuntu/Debian locations
    local DTB_ROOT=""
    local SEARCH_PATHS=(
        "$WORK_DIR/extracted/lib/firmware"/*/device-tree
        "$WORK_DIR/extracted/usr/lib/linux-image-*"
    )

    for path in "${SEARCH_PATHS[@]}"; do
        # We look for a directory that actually contains .dtb files
        if [ -d "$path" ] && [ -n "$(find "$path" -name "*.dtb" -print -quit)" ]; then
            DTB_ROOT="$path"
            echo "Found DTB directory inside deb: $DTB_ROOT" >&2
            break
        fi
    done

    if [ -z "$DTB_ROOT" ]; then
        echo "Error: Could not find DTB files in standard paths within .deb" >&2
        rm -rf "$WORK_DIR"
        exit 1
    fi

    # 3. Create Fake KOBJ Structure
    # ITS files usually expect: arch/arm64/boot/dts/qcom/*.dtb
    local FAKE_KOBJ="$WORK_DIR/kobj"
    mkdir -p "$FAKE_KOBJ/arch/arm64/boot/dts/qcom"

    # Copy/Link DTBs
    # We copy recursively to the qcom/ folder.
    cp -r "$DTB_ROOT"/* "$FAKE_KOBJ/arch/arm64/boot/dts/qcom/" 2>/dev/null || cp -r "$DTB_ROOT"/* "$FAKE_KOBJ/arch/arm64/boot/dts/"

    # Return the new path to the caller (THIS goes to stdout)
    echo "$FAKE_KOBJ"
}

# Resolve paths
OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"
METADATA_DTS_PATH="$(realpath "$METADATA_DTS_PATH")"
FIT_IMAGE_ITS_PATH="$(realpath "$FIT_IMAGE_ITS_PATH")"

# Logic Switch: Use existing kobj or process .deb?
if [ -n "$KERNEL_DEB" ]; then
    KERNEL_DEB="$(realpath "$KERNEL_DEB")"
    if [ ! -f "$KERNEL_DEB" ]; then
        echo "Error: .deb file not found at $KERNEL_DEB"
        exit 1
    fi
    # Override KERNEL_BUILD_ARTIFACTS with our temporary structure
    KERNEL_BUILD_ARTIFACTS=$(process_kernel_deb "$KERNEL_DEB")
else
    # Standard behavior
    KERNEL_BUILD_ARTIFACTS="$(realpath "$KERNEL_BUILD_ARTIFACTS")"
fi

# Function to create FIT image
function create_fit_image() {
    # Cleaning previous FIT image artifacts
    rm -f "${OUTPUT_DIR}/fit_dtb.bin"
    rm -rf "${OUTPUT_DIR}/fit_dir"
    
    # Clean up temp files in the artifact dir (works for both real kobj and fake one)
    rm -f "${KERNEL_BUILD_ARTIFACTS}/qcom-fitimage.its"
    rm -f "${KERNEL_BUILD_ARTIFACTS}/qcom-metadata.dtb"

    # Creating output directory
    mkdir -p "$OUTPUT_DIR/fit_dir"

    # Copying ITS file to kernel build artifacts path
    cp "$FIT_IMAGE_ITS_PATH" "${KERNEL_BUILD_ARTIFACTS}/qcom-fitimage.its"

    # Compiling metadata DTS to DTB
    dtc -I dts -O dtb -o "${KERNEL_BUILD_ARTIFACTS}/qcom-metadata.dtb" "${METADATA_DTS_PATH}"

    echo "Generating FIT image..."
    
    # Store current dir
    pushd "$KERNEL_BUILD_ARTIFACTS" > /dev/null
    
    # mkimage needs to run relative to the artifacts so it finds 'arch/arm64/...'
    mkimage -f "qcom-fitimage.its" "${OUTPUT_DIR}/fit_dir/qclinux_fit.img" -E -B 8
    
    # Restore dir
    popd > /dev/null

    echo "Packing final image into fit_dtb.bin..."
    
    # Use SCRIPT_DIR to locate the helper script
    if [ ! -x "${SCRIPT_DIR}/generate_boot_bins.sh" ]; then
        echo "Error: generate_boot_bins.sh not found at ${SCRIPT_DIR}"
        exit 1
    fi
    "${SCRIPT_DIR}/generate_boot_bins.sh" bin --input "${OUTPUT_DIR}/fit_dir" --output "${OUTPUT_DIR}/fit_dtb.bin"
}

echo "Starting FIT image creation..."
create_fit_image
echo "FIT image created at ${OUTPUT_DIR}/fit_dtb.bin"

# Cleanup if we used a temp dir for .deb
if [ -n "$KERNEL_DEB" ] && [[ "$KERNEL_BUILD_ARTIFACTS" == /tmp/* ]]; then
    # KERNEL_BUILD_ARTIFACTS is .../tmp.xxxx/kobj. We want to remove the parent tmp dir.
    rm -rf "$(dirname "$KERNEL_BUILD_ARTIFACTS")"
fi
