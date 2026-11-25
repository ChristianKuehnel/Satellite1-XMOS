// Copyright 2026 Future Proof Homes

#include <stdio.h>
#include "audio_pipeline_dsp.h"

#if !appconfAUDIO_PIPELINE_SKIP_NS
/* Stub only the DSP; the test exercises the firmware's actual routing code. */
void ns_process_frame(ns_state_t *state, int32_t output[NS_FRAME_ADVANCE],
                      const int32_t input[NS_FRAME_ADVANCE])
{
    (void)state;
    for (unsigned i = 0; i < NS_FRAME_ADVANCE; i++) {
        output[i] = input[i] / 2;
    }
}
#endif

int main(void)
{
    frame_data_t frame = {0};
    for (unsigned i = 0; i < ARRAY_FRAME_ADVANCE; i++) {
        frame.samples[0][i] = 2000 + 2 * (int32_t)i;
        frame.aec_reference_audio_samples[0][i] = 100;
        frame.aec_reference_audio_samples[1][i] = -100;
    }

    array_process_ns_frame(NULL, &frame);

    for (unsigned i = 0; i < ARRAY_FRAME_ADVANCE; i++) {
        int32_t expected = 2000 + 2 * (int32_t)i;
#if !appconfAUDIO_PIPELINE_SKIP_NS
        expected /= 2;
#endif
        if (frame.samples[0][i] != expected ||
            frame.aec_reference_audio_samples[1][i] != expected ||
            frame.aec_reference_audio_samples[0][i] != 100) {
            fprintf(stderr, "Unexpected NS routing at sample %u\n", i);
            return 1;
        }
    }
    return 0;
}
