"""Exercise the firmware stereo EQ without XMOS hardware or fwk_voice."""

import ctypes
import math
import os
import shlex
import subprocess
from pathlib import Path

import numpy as np
import pytest


TEST_DIR = Path(__file__).resolve().parent
FIRMWARE_SRC = TEST_DIR.parents[1] / "satellite-xmos-firmware" / "src"
SAMPLE_RATE = 48_000
FRAME_LENGTH = 720
MIN_SAMPLE, MAX_SAMPLE = -(1 << 31), (1 << 31) - 1
BANDS = [(1825, -7.7, 2.0), (3542, -10.0, 2.66), (166, -6.1, 1.1)]


@pytest.fixture(scope="module")
def process_eq(tmp_path_factory):
    library = tmp_path_factory.mktemp("speaker_eq") / "speaker_eq.so"
    subprocess.run(
        [
            *shlex.split(os.environ.get("CC", "cc")),
            "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-shared", "-fPIC",
            "-I", str(FIRMWARE_SRC),
            str(TEST_DIR / "speaker_eq_host.c"), "-o", str(library),
        ],
        check=True,
    )
    process = ctypes.CDLL(str(library)).speaker_eq_process
    process.argtypes = [
        np.ctypeslib.ndpointer(dtype=np.int32, ndim=2, flags="C_CONTIGUOUS"),
        ctypes.c_size_t,
        ctypes.c_size_t,
    ]
    process.restype = None

    def run(stereo, frame_length=FRAME_LENGTH):
        # Sentinels detect a stride that writes beyond the interleaved buffer.
        guarded = np.full((len(stereo) + 2, 2), 123456, dtype=np.int32)
        samples = guarded[1:-1]
        samples[:] = stereo
        process(samples, len(stereo), frame_length)
        np.testing.assert_array_equal(guarded[[0, -1]], 123456)
        return samples.copy()

    return run


def cookbook_coefficients():
    for frequency, gain, q in BANDS:
        omega = math.tau * frequency / SAMPLE_RATE
        amplitude = 10 ** (gain / 40)
        alpha = math.sin(omega) / (2 * q)
        a0 = 1 + alpha / amplitude
        middle = -2 * math.cos(omega)
        yield (
            (1 + alpha * amplitude) / a0,
            middle / a0,
            (1 - alpha * amplitude) / a0,
            middle / a0,
            (1 - alpha / amplitude) / a0,
        )


def reference_q28(samples):
    """Independent recurrence using Cookbook coefficients and Python integers."""
    output = samples.tolist()
    for band in cookbook_coefficients():
        b0, b1, b2, a1, a2 = (round(x * (1 << 28)) for x in band)
        x1 = x2 = y1 = y2 = 0
        next_output = []
        for x in output:
            y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) // (1 << 28)
            y = max(MIN_SAMPLE, min(MAX_SAMPLE, y))
            next_output.append(y)
            x1, x2, y1, y2 = x, x1, y, y1
        output = next_output
    return output


@pytest.mark.parametrize("frequency", [20, 166, 500, 1825, 3542, 8000, 20000])
def test_frequency_response(process_eq, frequency):
    t = np.arange(2 * SAMPLE_RATE)
    tone = np.rint((1 << 26) * np.sin(math.tau * frequency * t / SAMPLE_RATE))
    output = process_eq(np.column_stack((tone, tone)))[:, 0]
    # Allow the filter to settle, then measure one second of steady-state audio.
    actual_db = 20 * np.log10(
        np.linalg.norm(output[SAMPLE_RATE:].astype(float))
        / np.linalg.norm(tone[SAMPLE_RATE:])
    )
    z = np.exp(-1j * math.tau * frequency / SAMPLE_RATE)
    response = math.prod(
        (b0 + b1 * z + b2 * z**2) / (1 + a1 * z + a2 * z**2)
        for b0, b1, b2, a1, a2 in cookbook_coefficients()
    )
    assert actual_db == pytest.approx(20 * np.log10(abs(response)), abs=0.02)


@pytest.mark.parametrize("kind", ["impulse", "step"])
def test_transient_response(process_eq, kind):
    amplitude = 1 << 26
    signal = np.zeros(4 * FRAME_LENGTH, dtype=np.int32)
    signal[:1 if kind == "impulse" else len(signal)] = amplitude
    output = process_eq(np.column_stack((signal, signal)))[:, 0]
    np.testing.assert_array_equal(output, reference_q28(signal))
    settled = 0 if kind == "impulse" else amplitude
    # Allow the small DC bias from truncating the feedback to integer samples.
    assert np.max(np.abs(output[-100:] - settled)) < (1 << 12)


@pytest.mark.parametrize("kind", ["step", "alternating"])
def test_full_scale_saturation(process_eq, kind):
    signal = np.full(4 * FRAME_LENGTH, MAX_SAMPLE, dtype=np.int32)
    if kind == "alternating":
        signal[1::2] = MIN_SAMPLE
    else:
        # Exercise both directions, including a transition between the rails.
        signal[2 * FRAME_LENGTH:] = MIN_SAMPLE
    output = process_eq(np.column_stack((signal, signal)))[:, 0]
    assert MIN_SAMPLE in output
    assert MAX_SAMPLE in output
    np.testing.assert_array_equal(output, reference_q28(signal))


@pytest.mark.parametrize("active_channel", [0, 1])
def test_stereo_isolation(process_eq, active_channel):
    samples = np.zeros((2 * FRAME_LENGTH, 2), dtype=np.int32)
    active = samples[:, active_channel]
    active[0] = active[FRAME_LENGTH - 1] = 1 << 27
    output = process_eq(samples)
    np.testing.assert_array_equal(output[:, 1 - active_channel], 0)
    np.testing.assert_array_equal(output[:, active_channel], reference_q28(active))


def test_frame_continuity(process_eq):
    count = 3 * FRAME_LENGTH + 17
    rng = np.random.default_rng(105)
    samples = rng.integers(MIN_SAMPLE, MAX_SAMPLE, endpoint=True, size=(count, 2))
    np.testing.assert_array_equal(process_eq(samples), process_eq(samples, count))
