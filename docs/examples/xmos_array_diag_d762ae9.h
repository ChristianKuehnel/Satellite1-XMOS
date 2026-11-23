#pragma once

#include <array>
#include <cstring>

#include "esphome/components/memory_flasher/memory_flasher.h"
#include "esphome/components/satellite1/satellite1.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

namespace esphome::xmos_array_diag_d762ae9 {

inline constexpr size_t DIAG_SIZE = 130;

inline bool ready(const satellite1::Satellite1 *sat, const memory_flasher::MemoryFlasher *flasher) {
  return sat->state == satellite1::SAT_XMOS_CONNECTED_STATE && flasher->state == memory_flasher::FLASHER_IDLE;
}

inline bool read(satellite1::Satellite1 *sat, const memory_flasher::MemoryFlasher *flasher,
                 uint8_t (&data)[DIAG_SIZE]) {
  if (!ready(sat, flasher))
    return false;

  // The request length includes the command status, not the response marker.
  constexpr uint8_t PAYLOAD_SIZE = DIAG_SIZE + 1;
  std::array<uint8_t, 3 + PAYLOAD_SIZE> frame{233, satellite1::CONTROL_CMD_READ_BIT, PAYLOAD_SIZE};
  sat->enable();
  sat->transfer_array(frame);
  sat->disable();
  if (frame[0] == satellite1::CONTROL_COMMAND_IGNORED_IN_DEVICE)
    return false;

  // Let the XMOS stage the reply, as the original ESPHome transfer() does.
  vTaskDelay(1);
  frame.fill(0);
  sat->enable();
  sat->transfer_array(frame);
  sat->disable();
  if (frame[0] != satellite1::DC_RET_STATUS::PAYLOAD_AVAILABLE ||
      frame[1] != satellite1::DC_RET_STATUS::CMD_SUCCESS)
    return false;

  std::memcpy(data, frame.data() + 2, DIAG_SIZE);
  return true;
}

}  // namespace esphome::xmos_array_diag_d762ae9
