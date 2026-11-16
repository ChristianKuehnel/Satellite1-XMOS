/*
 * Host harness for the fwk_voice single-threaded audio pipeline.
 *
 * Reads a 32-bit PCM WAV file with (AP_MAX_Y_CHANNELS + AP_MAX_X_CHANNELS)
 * interleaved channels - microphone (Y) channels first, then reference (X)
 * channels - runs the full pipeline (stage1/AEC -> IC+VNR -> NS -> AGC) and
 * writes a 32-bit PCM WAV with AP_MAX_Y_CHANNELS output channels at the same
 * sample rate.
 *
 * This is the host-buildable equivalent of the bare-metal-only
 * modules/voice/examples/pipeline app. It links the unmodified
 * modules/voice/examples/pipeline/src/pipeline.c from the fwk_voice
 * submodule together with the fwk_voice interface libraries.
 *
 * Usage: dsp_host_pipeline <input.wav> <output.wav>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xmath/xmath.h"

#include "pipeline_config.h"
#include "pipeline_state.h"

/* Declared in modules/voice/examples/pipeline/src/pipeline.c (no header) */
extern void pipeline_tile0_init(pipeline_state_tile0_t *state);
extern void pipeline_tile1_init(pipeline_state_tile1_t *state);

extern void pipeline_process_frame_tile0(pipeline_state_tile0_t *state,
        int32_t (*input_y_data)[AP_FRAME_ADVANCE],
        int32_t (*input_x_data)[AP_FRAME_ADVANCE],
        int32_t (*output_data)[AP_FRAME_ADVANCE],
        pipeline_metadata_t *md_output);

extern void pipeline_process_frame_tile1(pipeline_state_tile1_t *state, pipeline_metadata_t *md_input,
        int32_t (*input_data)[AP_FRAME_ADVANCE],
        int32_t (*output_data)[AP_FRAME_ADVANCE]);

#define INPUT_CHANNELS  (AP_MAX_Y_CHANNELS + AP_MAX_X_CHANNELS)
#define OUTPUT_CHANNELS (AP_MAX_Y_CHANNELS)
#define WAV_BIT_DEPTH   32

static int read_u32_le(FILE *f, uint32_t *v)
{
    uint8_t b[4];
    if (fread(b, 1, 4, f) != 4)
        return 0;
    *v = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    return 1;
}

/* Parse a RIFF/WAV header, walking chunks until 'data' is found.
 * Returns 0 on success. */
static int wav_parse_header(FILE *f, int *channels, int *sample_rate, int *bit_depth,
                            long *data_offset, long *data_size)
{
    unsigned char hdr[12];
    if (fread(hdr, 1, 12, f) != 12 ||
        memcmp(hdr, "RIFF", 4) != 0 || memcmp(hdr + 8, "WAVE", 4) != 0)
        return -1;

    *channels = 0;
    *sample_rate = 0;
    *bit_depth = 0;
    *data_offset = 0;
    *data_size = 0;

    while (1) {
        unsigned char tag[4];
        uint32_t size;
        if (fread(tag, 1, 4, f) != 4 || !read_u32_le(f, &size))
            break;

        if (memcmp(tag, "fmt ", 4) == 0) {
            unsigned char fmt[16];
            if (size < 16 || fread(fmt, 1, 16, f) != 16)
                return -1;
            *channels    = fmt[2] | (fmt[3] << 8);
            *sample_rate = fmt[4] | (fmt[5] << 8) | (fmt[6] << 16) | ((int)fmt[7] << 24);
            *bit_depth   = fmt[14] | (fmt[15] << 8);
            fseek(f, (long)(size - 16), SEEK_CUR);
        } else if (memcmp(tag, "data", 4) == 0) {
            *data_offset = ftell(f);
            *data_size   = (long)size;
            break;
        } else {
            fseek(f, (long)size, SEEK_CUR);
        }
        if (size & 1)
            fseek(f, 1, SEEK_CUR); /* chunks are word-aligned */
    }

    return (*channels != 0 && *bit_depth != 0 && *data_offset != 0) ? 0 : -1;
}

static void wav_write_header(FILE *f, int channels, int sample_rate, int bit_depth, long data_size)
{
    unsigned char h[44];
    memset(h, 0, sizeof(h));
    memcpy(h, "RIFF", 4);
    h[4]  = (uint8_t)(36 + data_size);
    h[5]  = (uint8_t)((36 + data_size) >> 8);
    h[6]  = (uint8_t)((36 + data_size) >> 16);
    h[7]  = (uint8_t)((36 + data_size) >> 24);
    memcpy(h + 8, "WAVE", 4);
    memcpy(h + 12, "fmt ", 4);
    h[16] = 16; /* fmt chunk size */
    h[20] = 1;  /* PCM */
    h[22] = (uint8_t)channels;
    h[24] = (uint8_t)sample_rate;
    h[25] = (uint8_t)(sample_rate >> 8);
    h[26] = (uint8_t)(sample_rate >> 16);
    h[27] = (uint8_t)(sample_rate >> 24);
    h[28] = (uint8_t)(sample_rate * channels * bit_depth / 8);
    h[29] = (uint8_t)(sample_rate * channels * bit_depth / 8 >> 8);
    h[30] = (uint8_t)(sample_rate * channels * bit_depth / 8 >> 16);
    h[31] = (uint8_t)(sample_rate * channels * bit_depth / 8 >> 24);
    h[32] = (uint8_t)(channels * bit_depth / 8);
    h[34] = (uint8_t)bit_depth;
    memcpy(h + 36, "data", 4);
    h[40] = (uint8_t)data_size;
    h[41] = (uint8_t)(data_size >> 8);
    h[42] = (uint8_t)(data_size >> 16);
    h[43] = (uint8_t)(data_size >> 24);

    if (fwrite(h, 1, sizeof(h), f) != sizeof(h)) {
        printf("Error: failed to write WAV header\n");
        _Exit(1);
    }
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        printf("Arguments missing. Expected: <input file name> <output file name>\n");
        return 1;
    }

    FILE *in = fopen(argv[1], "rb");
    if (!in) {
        printf("Error: cannot open %s\n", argv[1]);
        return 1;
    }
    FILE *out = fopen(argv[2], "wb");
    if (!out) {
        printf("Error: cannot open %s\n", argv[2]);
        fclose(in);
        return 1;
    }

    int channels = 0, sample_rate = 0, bit_depth = 0;
    long data_offset = 0, data_size = 0;
    if (wav_parse_header(in, &channels, &sample_rate, &bit_depth, &data_offset, &data_size) != 0) {
        printf("Error: unsupported or malformed WAV file %s\n", argv[1]);
        return 1;
    }
    if (bit_depth != WAV_BIT_DEPTH) {
        printf("Error: unsupported wav bit depth (%d) for %s. Only %d supported\n",
               bit_depth, argv[1], WAV_BIT_DEPTH);
        return 1;
    }
    if (channels != INPUT_CHANNELS) {
        printf("Error: wav num channels (%d) does not match pipeline (%d = %d mics + %d refs)\n",
               channels, INPUT_CHANNELS, AP_MAX_Y_CHANNELS, AP_MAX_X_CHANNELS);
        return 1;
    }

    long frame_count = data_size / (4 * INPUT_CHANNELS);
    unsigned block_count = (unsigned)(frame_count / AP_FRAME_ADVANCE);
    if (block_count == 0) {
        printf("Error: input too short (%ld samples)\n", frame_count);
        return 1;
    }

    wav_write_header(out, OUTPUT_CHANNELS, sample_rate, WAV_BIT_DEPTH,
                     (long)block_count * AP_FRAME_ADVANCE * 4 * OUTPUT_CHANNELS);

    int32_t input_read_buffer[AP_FRAME_ADVANCE * INPUT_CHANNELS];
    int32_t output_write_buffer[AP_FRAME_ADVANCE * OUTPUT_CHANNELS];
    int32_t DWORD_ALIGNED frame_y[AP_MAX_Y_CHANNELS][AP_FRAME_ADVANCE];
    int32_t DWORD_ALIGNED frame_x[AP_MAX_X_CHANNELS][AP_FRAME_ADVANCE];
    int32_t DWORD_ALIGNED tile0_output[AP_MAX_Y_CHANNELS][AP_FRAME_ADVANCE];
    int32_t DWORD_ALIGNED pipeline_output[AP_MAX_Y_CHANNELS][AP_FRAME_ADVANCE];

    pipeline_state_tile0_t DWORD_ALIGNED pipeline_tile0_state;
    pipeline_state_tile1_t DWORD_ALIGNED pipeline_tile1_state;
    pipeline_tile0_init(&pipeline_tile0_state);
    pipeline_tile1_init(&pipeline_tile1_state);

    long bytes_per_block = (long)AP_FRAME_ADVANCE * INPUT_CHANNELS * 4;

    for (unsigned b = 0; b < block_count; b++) {
        if (fseek(in, data_offset + (long)b * bytes_per_block, SEEK_SET) != 0 ||
            fread(input_read_buffer, 4, (size_t)AP_FRAME_ADVANCE * INPUT_CHANNELS, in)
                != (size_t)AP_FRAME_ADVANCE * INPUT_CHANNELS) {
            printf("Error: failed reading %s\n", argv[1]);
            _Exit(1);
        }

        /* Deinterleave: Y (mic) channels first, then X (reference) channels */
        for (unsigned f = 0; f < AP_FRAME_ADVANCE; f++) {
            for (unsigned ch = 0; ch < AP_MAX_Y_CHANNELS; ch++)
                frame_y[ch][f] = input_read_buffer[f * INPUT_CHANNELS + ch];
            for (unsigned ch = 0; ch < AP_MAX_X_CHANNELS; ch++)
                frame_x[ch][f] = input_read_buffer[f * INPUT_CHANNELS + AP_MAX_Y_CHANNELS + ch];
        }

        /* Tile 0: stage1 (AEC/DE/ADEC). Tile 1: IC+VNR, NS, AGC.
         * On host both run in-process; on target they run on separate tiles
         * and exchange md + AEC output over a channel. */
        pipeline_metadata_t md;
        pipeline_process_frame_tile0(&pipeline_tile0_state, frame_y, frame_x, tile0_output, &md);
        pipeline_process_frame_tile1(&pipeline_tile1_state, &md, tile0_output, pipeline_output);

        /* Interleave output channels */
        for (unsigned ch = 0; ch < OUTPUT_CHANNELS; ch++)
            for (unsigned f = 0; f < AP_FRAME_ADVANCE; f++)
                output_write_buffer[f * OUTPUT_CHANNELS + ch] = pipeline_output[ch][f];

        if (fwrite(output_write_buffer, 4, (size_t)AP_FRAME_ADVANCE * OUTPUT_CHANNELS, out)
                != (size_t)AP_FRAME_ADVANCE * OUTPUT_CHANNELS) {
            printf("Error: failed writing %s\n", argv[2]);
            _Exit(1);
        }
    }

    fclose(in);
    fclose(out);
    return 0;
}
