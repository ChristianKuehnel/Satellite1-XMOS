# Satellite1 XMOS firmware

## Variants
**satellite1_firmware_fixed_delay**

Uses the 'Automatic Delay Estimation and Correction' pipeline of the sln_voice example repository.

**satellite1_firmware_bypass**

A variant which bypasses the mic-pipeline. Hence, the raw mic signal is streamed to the ESP32-S3.

**satellite1_firmware_fixed_delay_4mic** (experimental)

Uses all four HAT microphones: 4-mic x 1-ref AEC followed by two IC paths (E/W and N/S), the best output selected by VNR.

**satellite1_firmware_fixed_delay_4mic_bf** (experimental)

Four-microphone beamformer variant: 8 fixed delay-and-sum beams, IC runs on the look and opposite beam with energy-based beam selection.

See `docs/four-mic-array.md` for details, known limitations and diagnostics.

## Firmware Files

**variant_name.factory.bin**

A complete image of the flash memory, including both the boot partition (containing the flash loader and factory image) and the data partition.

**variant_name.upgrade.bin**

A firmware upgrade image that can be uploaded through the Device Firmware Update (DFU) service. Requires a factory image with DFU support running on the device.


**variant_name.xe**

The XMOS executable (XE) binary format stores programs for XMOS devices and includes information about the system it is intended to run on, allowing support for multiple program loads, configurations and debugging.


## Flashing via Satellite1 ESPHome Firmware

The ESPHome firmware includes a `memory_flasher` component that can write the
XMOS factory image to QSPI flash over SPI. This is the **only method** for the
initial flash (the Satellite1 ships without pre-flashed XMOS firmware).

**Prerequisites:**
- ESPHome firmware with the `satellite1` board platform is running
- The configuration contains a `memory_flasher` with `platform: satellite1`
  and an `embed_flash_image` block (in the current Satellite1-ESPHome
  firmware this is the built-in flasher `xflash` in
  `config/satellite1.base.yaml`)

**Steps:**
1. Build the factory image: `make create_flash_img_satellite1_firmware_fixed_delay`
2. Copy `satellite1_firmware_fixed_delay.factory.bin` and `.factory.md5` to
   the ESPHome build directory (or use the auto-generated
   `build/embed_flash_imag.yaml`, which already contains the correct
   `image_version` and local paths).
3. Update the `image_version` in your ESPHome config to the version embedded
   in the image (see `build/embed_flash_imag.yaml`; for `dev` in
   `firmware_version.txt` the build resolves the actual dev version, e.g.
   `v1.1.0-dev` or `v1.1.0-dev.100` with `-DUSE_DEV_TRACKING=ON`).
4. Re-flash the ESPHome firmware. On boot, the `memory_flasher` component
   writes the XMOS image to QSPI and verifies the MD5 checksum.

See `docs/versioning.md` for the full ESPHome YAML integration.

## Testing a new firmware on the device via ESPHome

To test a new firmware build (an automatic dev build from GitHub or a local
build) on the device, the factory image is embedded into the ESP32 firmware
and the `memory_flasher` component writes it to the XMOS QSPI flash. The
Satellite1-ESPHome firmware does this automatically on boot by default: if
the XMOS does not respond, or reports a version different from the embedded
image, the embedded image is flashed. Set the substitution
`xmos_auto_flash_on_boot: "false"` to keep manual control instead (the
dashboard then offers a manual XMOS flash button).

### Using an automatic dev build from GitHub

The **Dev Build** workflow publishes factory images to GitHub Releases on
every push to `develop` (see [Development builds](#development-builds)). No
local toolchain is required:

1. Download the factory image (and checksum) from the rolling `dev-latest`
   release, or from a pinned `dev-YYYYMMDD-<sha>` release for a specific
   commit:

   ```bash
   curl -LO https://github.com/FutureProofHomes/Satellite1-XMOS/releases/download/dev-latest/satellite1_firmware_fixed_delay.factory.bin
   curl -LO https://github.com/FutureProofHomes/Satellite1-XMOS/releases/download/dev-latest/satellite1_firmware_fixed_delay.factory.bin.sha256
   sha256sum -c satellite1_firmware_fixed_delay.factory.bin.sha256
   ```

2. The flasher verifies images by MD5, but dev releases only carry a
   `.sha256` checksum. Generate an MD5 file next to the image:

   ```bash
   md5sum -q satellite1_firmware_fixed_delay.factory.bin > satellite1_firmware_fixed_delay.factory.md5
   ```

3. In your final ESPHome YAML (Satellite1-ESPHome), extend the built-in
   flasher `xflash` with the dev image:

   ```yaml
   memory_flasher:
     - id: !extend xflash
       embed_flash_image:
         image_version: v1.1.0-dev
         image_file: /path/to/satellite1_firmware_fixed_delay.factory.bin
         md5_file: /path/to/satellite1_firmware_fixed_delay.factory.md5
   ```

   `image_version` must be a valid version string (e.g. `v1.1.0-dev`); it is
   the version compiled into the dev build (stated in the release body) and
   the one the device compares against on boot.

4. Build and upload the ESP32 firmware:

   ```bash
   esphome compile config/satellite1.yaml
   esphome upload config/satellite1.yaml
   ```

The MD5 is checked at ESPHome compile time and again on the device while
flashing. After the reboot the device flashes the embedded image and reports
the new version in the boot log and the `xmos_firmware_version_text` text
sensor.

### Using a local build

1. Build the factory image (see [Building the firmware locally](#building-the-firmware-locally)).
   The build generates `satellite1_firmware_fixed_delay.factory.md5` and an
   auto-generated `build/embed_flash_imag.yaml` flasher snippet containing
   the exact `image_version` and the local image paths.
2. Merge that snippet into the ESPHome configuration (extend the built-in
   flasher `xflash`), then build and upload the ESP32 firmware as above.

The experimental four-mic variants follow the same flow: build
`create_flash_img_satellite1_firmware_fixed_delay_4mic` (or `_4mic_bf`) and
point the flasher at that factory image. NS, AGC and the I2S output are
identical to the production variant, so no other ESPHome changes are needed
(see `docs/four-mic-array.md`).

## Flashing via dfu-util
> **Note:** The Satellite1 does not come with a pre-flashed XMOS firmware. Hence, the initial firmware needs to be written directly to the flash memory via SPI. Use 'Flashing via Satellite1 ESPHome Firmware' in this case.  


If the XMOS device is running a factory firmware with DFU over USB support, an upgrade image can be uploaded as follows:
```bash
dfu-util -e -a 1 -D variant_name.upgrade.bin
```


## Running / Flashing via xTAG
> **Note**: The Satellite1 does not include an xTAG debugger. This option applies only when testing the firmware with a developer board like the XCORE.AI EVALUATION KIT. 

When the XMOS board is connected as a USB xTag device, the firmware can be run or flashed as follows:

Running without flashing:

```bash
xrun --xscope variant_name.xe
```

Flashing:
```bash
xflash --quad-spi-clock 50MHz --factory variant_name.xe --boot-partition-size 0x100000 --data variant_name_data_partition.bin
```


## Development builds

Every push to `develop` triggers the **Dev Build** workflow (`.github/workflows/dev-build.yml`), which builds the firmware in the official XCORE builder container and publishes it to GitHub Releases. No local toolchain is needed to obtain a build.

Two kinds of development release are produced:

- **`dev-latest`** – a rolling pre-release that always points at the most recent successful build. Its assets are replaced on each push.
- **`dev-YYYYMMDD-<sha>`** – an immutable pre-release per push. Each push keeps a permanent, addressable artifact that is never overwritten.

Each release contains:

- `satellite1_firmware_fixed_delay.factory.bin` (+ `.sha256`) – full flash image
- `satellite1_firmware_fixed_delay.upgrade.bin` (+ `.sha256`) – DFU upgrade image

The exact commit embedded in each binary can be recovered from `git describe`:
the build identifier is compiled into the image and reported by the DFU
`GETVERSION` service.

The workflow also maintains a machine-readable index served from the GitHub
Pages branch:

```
https://raw.githubusercontent.com/FutureProofHomes/Satellite1-XMOS/heads/gh-pages/releases.json
```

It lists the current `dev-latest` build plus the most recent pinned builds
(commit, version, `git describe`, timestamp, and release URL).

To install one of these dev builds on the device, see
[Testing a new firmware on the device via ESPHome](#testing-a-new-firmware-on-the-device-via-esphome).

A **Dev Cleanup** workflow (`.github/workflows/dev-cleanup.yml`) runs monthly to
delete pinned `dev-*` pre-releases older than 180 days. It never removes
`dev-latest` or any real (non-pre-release) release.

> **Note:** Development builds are unsigned, unreleased artifacts. Validate the
> `.sha256` checksum before flashing, and prefer the stable releases for
> production devices.

## Building the firmware locally

### Clone repository

```bash
git clone https://github.com/FutureProofHomes/Satellite1-XMOS.git
cd Satellite1-XMOS
git submodule update --init --recursive
```

### Setup XTC-Tools
Download XTX-15.3.1 from https://www.xmos.com/software-tools/

On Mac, the original software requires installing into `/Applications`. If you want to install into another directory, change `XMOS_TOOL_PATH` in `${INSTALL_DIR}/SetEnv.sh` to :
```bash
export XMOS_TOOL_PATH=${0:A:h};
```

### Setup Python Virtual Environment
The `xmos-ai-tools` python package is required for building the firmware modules.
It is recommended to install it into a virtual environment:

```bash
python3.10 -m venv .venv
source activate .venv/bin/activate
pip install -r requirements.txt
```

for later builds simply activate the environment before calling cmake:
```bash
source activate .venv/bin/activate
```


### Creating factory and upgrade images

On Linux and Mac run:

```bash
cmake -B build --toolchain xmos_cmake_toolchain/xs3a.cmake
cd build

make create_flash_img_variant_name
make create_upgrade_img_variant_name
```

On Windows run:
```bash
cmake -G Ninja -B build --toolchain xmos_cmake_toolchain/xs3a.cmake
cd build

ninja create_flash_img_variant_name
ninja create_upgrade_img_variant_name
```

### Building the XMOS executable only (.xe file)
Run the following commands in the root folder to build the firmware.

On Linux and Mac run:

```bash
cmake -B build --toolchain xmos_cmake_toolchain/xs3a.cmake
cd build

make variant_name
```

On Windows run:
```bash
cmake -G Ninja -B build --toolchain xmos_cmake_toolchain/xs3a.cmake
cd build

ninja variant_name
```





