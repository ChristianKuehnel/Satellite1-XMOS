# Four-microphone array (experimental)

Two additional firmware targets use all four Satellite1 HAT microphones. The
production target `satellite1_firmware_fixed_delay` is unchanged.

| Target | Microphones | AEC | Front end before IC |
| --- | --- | --- | --- |
| `satellite1_firmware_fixed_delay` (production) | E, W | 2 mic x 2 ref | none: IC on (E, W) |
| `satellite1_firmware_fixed_delay_4mic` | E, W, N, S | 4 mic x 1 ref | two IC paths, (E, W) and (N, S); best output VNR wins |
| `satellite1_firmware_fixed_delay_4mic_bf` | E, W, N, S | 4 mic x 1 ref | 8 fixed delay-and-sum beams; IC gets look and opposite beam |

NS, AGC and the two-lane I2S output to the ESP32 are identical in all three, so
no ESPHome change is needed to run them.

## Geometry

From `Satellite1-Hardware` `hat/rev4.1hat3D.step` and `hat/rev6.1hat3D.step`:
MK1..MK4 (CUI CMM-4030DT-261280-TR) on a 32.08 mm radius circle, 90 degrees
apart. Adjacent spacing 45.37 mm, opposite 64.16 mm. Maximum inter-microphone
delay 187 us (2.99 samples at 16 kHz). See `audio_pipelines/array/array_config.h`
for the data-line and SEL wiring and what can and cannot be inferred from it
(the handedness of the E/W/N/S labels is not verifiable from source).

## Why these choices

* **fwk_voice v0.9.0**: `AEC_MAX_Y_CHANNELS` / `AEC_MAX_X_CHANNELS` became
  compile-time options. v0.8.0 hard-coded 2, which is why
  `experiment/satellite1-4y1x-aec-residual-average` forked lib_aec.
* **4 mic x 1 ref AEC**: `aec_state_t` is 216 KB for 2x2, 376 KB for 4x2 and
  211 KB for 4x1 (10 main / 5 shadow phases). 4x2 cannot fit tile 1. The
  TAS2780 plays one mono signal, by default the (L+R)/2 downmix set by
  ESPHome, so a (L+R)/2 reference models the internal speaker exactly.
* **No naive summing**: averaging the four AEC outputs without alignment (as
  the experiment branch did) has a null at 3.78 kHz for a talker at 45 degrees
  and at 5.35 kHz at 0 degrees, and is -8 to -10 dB at 3 kHz.
* **IC stays two-channel**: lib_ic is fixed at one target and one reference
  channel ("NOT USER MODIFIABLE"), so the front end reduces 4 to 2.

## Known limitations

* With the TAS2780 in Left-only or Right-only mode and stereo content, or a
  stereo line-out speaker, the mono reference cannot model the echo (the host
  test measures ~0 dB ERLE for uncorrelated L/R in that case). Set
  `appconfARRAY_REF_MIX` to match, or keep the 2-mic build for those setups.
* The beam build feeds beams, not raw microphones, to IC, which XMOS tuned
  for a ~71 mm raw pair. IC re-adapts after a beam change.
* Beam selection follows the strongest pre-emphasised energy during speech; a
  louder talker (e.g. TV dialogue) can win. Wake-word-assisted locking needs
  an ESP32 to XMOS message and is future work.
* Nothing here has been measured on hardware yet: XU316 timing and memory fit
  must be confirmed with the diagnostics below and the build `-report`.

## Building

```bash
cmake -B build --toolchain xmos_cmake_toolchain/xs3a.cmake -DUSE_DEV_TRACKING=ON
cd build
make create_flash_img_satellite1_firmware_fixed_delay_4mic
make create_flash_img_satellite1_firmware_fixed_delay_4mic_bf
```

Add `-DSAT1_ARRAY_DEV_TAP=ON` for a development build that can route raw, AEC
or beam signals onto the output lanes. Never ship a dev-tap build.

CI-style build in the XMOS builder container:
`tools/ci/build_firmware.sh tools/ci/firmwares_array_dev.txt`.

## Reading Beamforming Diagnostics with ESPHome

### Prerequisites

- A Satellite1 already running XMOS firmware
  `satellite1_firmware_fixed_delay_4mic_bf`. No dev tap is needed. The
  non-beam four-mic build exposes the same layout in pair mode; the production
  two-mic build does not expose this resource.
- An existing Satellite1 ESPHome configuration using the standard IDs
  `satellite1_id` and `xflash` from
  [`satellite1.base.yaml`][sat1-base], and ESPHome 2026.10.2 or newer.

### Pin the Satellite1-ESPHome dependency for either example

Replace the existing Satellite1 entry under `packages:` in your **device
YAML** with the one below. If the entry is a shorthand `github://...` include,
replace it rather than loading both. Keep your other packages and device
settings (such as `esphome:`, `wifi:` and `logger:`).

```yaml
packages:
  FutureProofHomes.Satellite1:
    url: &sat1_url https://github.com/FutureProofHomes/Satellite1-ESPHome
    ref: &sat1_ref 95c05f56677063d5312b087ba751c7c07313a2e0
    files:
      - config/satellite1.base.yaml
      - config/common/dashboard_build.yaml
      - path: config/common/components.external.yaml
        vars:
          ext_comp_repo_url: *sat1_url
          ext_comp_repo_ref: *sat1_ref

substitutions:
  xmos_auto_flash_on_boot: "false"
```

This pins both the YAML package and the external C++ components to the
[same tested revision][sat1-rev]. If you have separate `external_components:`
overrides for `satellite1` or `memory_flasher`, remove them so the pinned
package supplies both. Updating ESPHome itself, or switching branches in
Satellite1-XMOS, does not update these components.

Merge the substitution into your existing `substitutions:` block. It stops
boot-time version mismatch checks from automatically replacing the experimental
XMOS image, but does not cancel a flash already scheduled for the next boot
or recovery from an interrupted flash.

Choose **one** example below and merge it into the same device YAML. If
`interval:` or `sensor:` already exists, append the list entries rather than
declaring the key twice. Clean the device's build files and rebuild. Upload
the resulting ESPHome configuration to the ESP32; you do not need to reflash
the XMOS.

### A. Raw diagnostic logging

```yaml
interval:
  - interval: 5s
    then:
      - lambda: |-
          if (!id(satellite1_id).is_xmos_connected() ||
              id(xflash).in_progress() || id(xflash).boot_flash_pending())
            return;
          uint8_t data[130]{};
          if (!id(satellite1_id).transfer(233, 0x80, data, sizeof(data))) {
            ESP_LOGW("xmos_array", "Diagnostic read failed");
            return;
          }
          ESP_LOGI("xmos_array", "Diagnostics v%u, mode %u (%u bytes): %s",
                   unsigned(data[0]), unsigned(data[1]), unsigned(sizeof(data)),
                   format_hex_pretty(data, sizeof(data), ' ', false).c_str());
```

Open **Logs** for the device in ESPHome Device Builder, or run
`esphome logs <device.yaml>`. Use `logger` level `INFO` or more verbose (the
standard configuration uses `DEBUG`). Look for `xmos_array`. Example prefix
(the real line contains all 130 bytes):

```text
[I][xmos_array:...]: Diagnostics v1, mode 2 (130 bytes): 01 02 03 00 40 01 00 00 02 00 00 00 3E F4 ...
```

This example shows beam 3, 320 processed frames, two beam changes and a first
microphone RMS of −30.10 dBFS.

### B. Home Assistant diagnostic sensors

```yaml
sensor:
  - {platform: template, id: xmos_mic_e, name: "XMOS Mic E RMS", unit_of_measurement: "dBFS",
     accuracy_decimals: 2, entity_category: diagnostic, state_class: measurement, update_interval: never}
  - {platform: template, id: xmos_mic_w, name: "XMOS Mic W RMS", unit_of_measurement: "dBFS",
     accuracy_decimals: 2, entity_category: diagnostic, state_class: measurement, update_interval: never}
  - {platform: template, id: xmos_mic_n, name: "XMOS Mic N RMS", unit_of_measurement: "dBFS",
     accuracy_decimals: 2, entity_category: diagnostic, state_class: measurement, update_interval: never}
  - {platform: template, id: xmos_mic_s, name: "XMOS Mic S RMS", unit_of_measurement: "dBFS",
     accuracy_decimals: 2, entity_category: diagnostic, state_class: measurement, update_interval: never}
  - {platform: template, id: xmos_beam, name: "XMOS Selected Beam",
     accuracy_decimals: 0, entity_category: diagnostic, update_interval: never}
  - {platform: template, id: xmos_beam_score, name: "XMOS Selected Beam Score", unit_of_measurement: "dBFS",
     accuracy_decimals: 2, entity_category: diagnostic, state_class: measurement, update_interval: never}
  - {platform: template, id: xmos_mic_e_erle, name: "XMOS Mic E AEC ERLE", unit_of_measurement: "dB",
     accuracy_decimals: 2, entity_category: diagnostic, state_class: measurement, update_interval: never}
  - {platform: template, id: xmos_frontend_time, name: "XMOS Front-End DSP Average", unit_of_measurement: "ms",
     accuracy_decimals: 3, entity_category: diagnostic, state_class: measurement, update_interval: never}
  - {platform: template, id: xmos_deadline_misses, name: "XMOS DSP Deadline Misses",
     accuracy_decimals: 0, entity_category: diagnostic, state_class: total_increasing, update_interval: never}
  - {platform: template, id: xmos_dropped_est, name: "XMOS Estimated Dropped Mic Frames",
     accuracy_decimals: 0, entity_category: diagnostic, update_interval: never}

interval:
  - interval: 5s
    then:
      - lambda: |-
          uint8_t p[130]{};
          const bool ready = id(satellite1_id).is_xmos_connected() &&
                             !id(xflash).in_progress() && !id(xflash).boot_flash_pending();
          const bool read_ok = ready && id(satellite1_id).transfer(233, 0x80, p, sizeof(p));
          const bool valid = read_ok && p[0] == 1 && p[1] == 2 && p[2] < 8;
          if (ready && !read_ok)
            ESP_LOGW("xmos_array", "Diagnostic read failed");
          if (read_ok && !valid)
            ESP_LOGW("xmos_array", "Unsupported diagnostics: version=%u mode=%u selected=%u",
                     unsigned(p[0]), unsigned(p[1]), unsigned(p[2]));

          auto cdb = [&p](unsigned i) -> float {
            const int32_t v = p[i] | (p[i + 1] << 8);
            return (v < 0x8000 ? v : v - 0x10000) / 100.0f;
          };
          auto u32 = [&p](unsigned i) -> uint32_t {
            return uint32_t(p[i]) | (uint32_t(p[i + 1]) << 8) |
                   (uint32_t(p[i + 2]) << 16) | (uint32_t(p[i + 3]) << 24);
          };
          id(xmos_mic_e).publish_state(valid ? cdb(12) : NAN);
          id(xmos_mic_w).publish_state(valid ? cdb(14) : NAN);
          id(xmos_mic_n).publish_state(valid ? cdb(16) : NAN);
          id(xmos_mic_s).publish_state(valid ? cdb(18) : NAN);
          id(xmos_beam).publish_state(valid ? float(p[2]) : NAN);
          id(xmos_beam_score).publish_state(valid ? cdb(64 + 2 * p[2]) : NAN);
          id(xmos_mic_e_erle).publish_state(valid && p[82] ? cdb(52) : NAN);
          id(xmos_frontend_time).publish_state(valid ? u32(94) / 100000.0f : NAN);
          id(xmos_deadline_misses).publish_state(valid ? float(u32(110)) : NAN);
          id(xmos_dropped_est).publish_state(valid ? float(u32(118)) : NAN);
```

After the ESPHome device reconnects, go to **Settings → Devices & services →
ESPHome → your Satellite1** in Home Assistant and look under **Diagnostic**
for the `XMOS` entities. All sensors share one poll. A skipped, failed or
incompatible read publishes unknown (`NaN`), not zero. Mic E ERLE also shows
unknown when the playback reference is inactive. The beam index is a category,
not a measurement to average. Deadline misses count up until XMOS resets (or
the counter wraps); the dropped-frame estimate is a high-water estimate, not a
counter of observed losses. ESPHome numeric sensors are floats, so they
cannot represent every integer above 2²⁴ exactly; use the raw dump for exact
large counter values.

### Protocol and fields

The public [`Satellite1::transfer()`][sat1-api] can be called from a lambda:

```cpp
bool transfer(uint8_t resource_id, uint8_t command, uint8_t *payload,
              uint8_t payload_len, bool *status_report_received = nullptr,
              bool retry = true);
```

The component uses the existing 8 MHz, mode 3 device-control SPI link. For a
read (command bit `0x80`), it sends a request and then a zero-filled SPI
transaction to clock out the response. It returns `true` and overwrites the
buffer only after receiving a payload-available marker with a successful
command status. `false` means no usable reply (for example, SPI is disabled,
the request was ignored, or the command failed). The optional status-report
flag concerns the controller's status registers, not the read result.

For resource `233`, read command `0x80`, pass **130** to `transfer()`. The
component puts **131** in the wire length byte to include the command status
and strips both the payload-available marker and status from the returned
buffer. ESPHome clocks `payload_len + 3` bytes, so the XMOS 256-byte SPI
buffers physically allow at most 253 caller bytes per transaction. The
[device-control protocol](device-control-spi-protocol.md#request-wire-format)
specifies a 253-byte *framed payload* limit; stay within 252 caller bytes for
reads to leave room for the status byte. The diagnostic read fits in either
limit, and the servicer rejects shorter requests: it has no partial-read
command.

[`array_diag.c`][diag-c] copies [`array_diag_status_t`][diag-h] verbatim after
the status byte. It is packed (no padding or alignment gaps), little-endian,
and exactly 130 bytes in diagnostic version 1. The offsets below are within
the ESPHome buffer, not the SPI frame. Mic arrays are ordered E, W, N, S per
the firmware's labels. `i16` is signed two's complement; `u8`, `u16` and
`u32` are unsigned; the number is the bit width. For timing, 100 ticks = 1 µs
and 100,000 ticks = 1 ms. A frame is 15 ms.

| Byte offset | Type | Field and interpretation |
| --- | --- | --- |
| 0 | u8 | `version`: diagnostic layout version (`1`), not the SPI protocol or firmware release version |
| 1 | u8 | `frontend_mode`: `1` = pair selection; `2` = beamforming |
| 2 | u8 | `selected`: beam 0–7 in 45° steps, or pair `0` = E/W, `1` = N/S |
| 3 | u8 | `ref_mix`: `0` = L/R downmix, `1` = left, `2` = right |
| 4, 8 | u32 each | `frames`, `switch_count`: processed frames and beam/pair changes since boot |
| 12–19 | i16 × 4 | `raw_rms_cdb`: smoothed input RMS after fixed 10× gain, before AEC; divide by 100 for dBFS |
| 20–27 | i16 × 4 | `raw_peak_cdb`: input peak hold; divide by 100 for dBFS |
| 28–43 | u32 × 4 | `raw_clip_count`: cumulative near-full-scale samples (≥ −0.009 dBFS) |
| 44–51 | i16 × 4 | `aec_rms_cdb`: smoothed post-AEC RMS; divide by 100 for dBFS |
| 52–59 | i16 × 4 | `aec_erle_cdb`: running input-to-residual power ratio; divide by 100 for dB; meaningful only while `ref_active` |
| 60, 62 | i16 each | `frontend_rms_cdb`, `output_rms_cdb`: IC output before NS and final AGC output on I2S lane 0; divide by 100 for dBFS |
| 64–79 | i16 × 8 | `score_cdb`: smoothed pre-emphasised beam energy (divide by 100 for dBFS, not raw mic loudness); in pair mode only the first two entries are used, as VNR × 10,000 |
| 80 | u16 | `vnr_x10000`: voice-to-noise ratio predictor output for the selected path; divide by 10,000 for a value between 0 and 1 |
| 82 | u8 | `ref_active`: `0` = inactive, `1` = active |
| 83–85 | u8 each | `tap_mode`, `tap_a`, `tap_b`: dev-tap mode and two channel/beam indices; mode is `0xFF` when not compiled in (`0` off, `1` raw, `2` AEC, `3` front end, `4` beams) |
| 86, 90 | u32 each | `t1_aec_ticks_avg`, `t1_aec_ticks_max`: tile 1 AEC, last publication window average and since-boot maximum |
| 94, 98 | u32 each | `t0_frontend_ticks_avg`, `t0_frontend_ticks_max`: tile 0 front end + IC + VNR, last publication window average and since-boot maximum |
| 102, 106 | u32 each | `t0_ns_ticks_max`, `t0_agc_ticks_max`: since-boot maxima for noise suppression and AGC |
| 110 | u32 | `deadline_misses`: stage executions exceeding the 15 ms frame budget, not a count of distinct lost frames |
| 114 | u32 | `t1_input_late_ticks_max`: maximum mic-input lateness versus expected cadence |
| 118 | u32 | `t1_dropped_frames_est`: highest estimate from sustained mic-input lateness, rounded to frames |
| 122, 126 | u32 each | `t0_heap_min_free`, `t1_heap_min_free`: minimum free heap since boot in bytes, per tile |

### Troubleshooting and limitations

- **Build errors mentioning `is_xmos_connected`, `in_progress`, or
  `boot_flash_pending`:** the build is using older Satellite1-ESPHome
  components. Apply the [package and component pin above](#pin-the-satellite1-esphome-dependency-for-either-example)
  and check for conflicting `external_components:` overrides before rebuilding.
  Don't remove the readiness checks: the older SPI reader also decodes replies
  differently.
- **No log lines:** check the logger level and verify that the XMOS is
  connected. The poll skips a disconnected XMOS and pending or active
  `xflash` work. The component also rejects device-control transfers while
  the SPI bus is in direct-flash mode or while the XMOS is settling at boot.
- **Truncated hex dump:** if you reduced `logger.tx_buffer_size`, restore the
  default of 512 bytes.
- **Repeated read failures or unsupported version/mode:** check which
  factory image `xflash` last wrote and verify that auto-flash is disabled.
  An occasional failed read is possible before the first snapshot or if a
  publish races the read. Keep polling at five seconds and check the next
  sample; do not shorten the request or add a tight retry loop.
- **Unchanging beam score:** the selector updates scores on speech frames,
  not during silence. Before the first speech frame it reports the
  initialized score of zero; version 1 has no score-valid flag.
- **Audio and timing:** polling reads a snapshot published about every
  240 ms, not live audio. It uses the existing SPI control link; audio
  continues over I2S, and the XMOS pipeline does not wait for the reader.
  `transfer()` is synchronous and briefly waits for SPI on the ESPHome main
  loop, so keep the polling interval conservative. A successful read does
  request a reset of the mic peak holds; running both examples would
  duplicate SPI traffic and change the peak-hold interval.
- **Verification:** ESPHome 2026.10.2 generated C++ for both examples with
  the pinned dependencies, and the ESP32-S3 toolchain compiled both generated
  `main.cpp` files. The decoding was checked against the firmware struct.
  Confirm on a Satellite1 that logs return version 1,
  mode 2, that mic levels and beam selection respond to sound, and that
  playback and voice capture remain uninterrupted while polling.

[sat1-rev]: https://github.com/FutureProofHomes/Satellite1-ESPHome/tree/95c05f56677063d5312b087ba751c7c07313a2e0
[sat1-base]: https://github.com/FutureProofHomes/Satellite1-ESPHome/blob/95c05f56677063d5312b087ba751c7c07313a2e0/config/satellite1.base.yaml
[sat1-api]: https://github.com/FutureProofHomes/Satellite1-ESPHome/blob/95c05f56677063d5312b087ba751c7c07313a2e0/esphome/components/satellite1/satellite1.h#L99-L140
[diag-c]: ../satellite-xmos-firmware/audio_pipelines/reference/fixed_delay_array/array_diag.c
[diag-h]: ../satellite-xmos-firmware/audio_pipelines/reference/fixed_delay_array/array_diag.h

## Host tests

```bash
cmake -S tests/test_array_host -B build_host && cmake --build build_host
ctest --test-dir build_host --output-on-failure
```

Builds lib_xcore_math's reference C implementation and lib_aec from source, and
checks: the 4x1 AEC state bounds and convergence, bit-exactness of the firmware
AEC driver against `aec_process_frame()` with the 4-channel schedule,
fractional-delay accuracy, beam patterns against the analytical model, beam
selection, the selector, and that the new `app_conf.h` constants reproduce the
2-mic production values. The pipeline sources are also type-checked against
the real fwk_voice headers with small stubs for the XTC/RTOS headers.
