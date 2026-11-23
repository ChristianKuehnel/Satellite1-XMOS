#include "eq/biquad_eq.h"

void speaker_eq_process(int32_t *samples, size_t count, size_t frame_length)
{
    biquad_state_t states[BIQUAD_EQ_CHANNELS][BIQUAD_EQ_NUM_BANDS] = {0};
    for (size_t i = 0; i < count; i += frame_length) {
        const size_t remaining = count - i;
        biquad_eq_process_stereo(samples + i * BIQUAD_EQ_CHANNELS, states,
                                 remaining < frame_length ? remaining : frame_length);
    }
}
