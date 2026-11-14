"""Host unit tests for the four-mic array frontend (beamformer, fractional delay, etc.)."""
import subprocess
from pathlib import Path
import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
BUILD_DIR = REPO_ROOT / "build-host" / "array"
BUILD_SCRIPT = REPO_ROOT / "tools" / "build_array_host.sh"


def _ensure_built():
    """Build the array host tests if not already built."""
    test_binary = BUILD_DIR / "test_array_frontend"
    if test_binary.exists():
        return
    if not BUILD_SCRIPT.exists():
        pytest.fail(f"Build script not found: {BUILD_SCRIPT}")
    result = subprocess.run(
        ["bash", str(BUILD_SCRIPT)],
        capture_output=True, text=True, timeout=300,
    )
    if result.returncode != 0:
        pytest.fail(
            f"Array host build failed (rc={result.returncode})\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    if not test_binary.exists():
        pytest.fail("Build completed but test binary not found.")


class TestArrayFrontend:
    """Array frontend C unit tests (plane-wave physics, beam selection, crossfade)."""

    def test_array_frontend(self):
        """Run the array_frontend C test binary."""
        _ensure_built()
        test_binary = BUILD_DIR / "test_array_frontend"
        result = subprocess.run(
            [str(test_binary)],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0:
            pytest.fail(
                f"array_frontend test FAILED (rc={result.returncode})\n"
                f"stdout:\n{result.stdout}\n"
                f"stderr:\n{result.stderr}"
            )
        assert "PASSED" in result.stdout, (
            f"Expected 'PASSED' in output, got:\n{result.stdout}"
        )


class TestArrayFrontendOutput:
    """Verify the array frontend test reports correct physics results."""

    def test_reports_beam_selection(self):
        """Test output should show beam selection results."""
        _ensure_built()
        test_binary = BUILD_DIR / "test_array_frontend"
        result = subprocess.run(
            [str(test_binary)],
            capture_output=True, text=True, timeout=60,
        )
        assert "8/8 select the right beam" in result.stdout, (
            f"Expected perfect on-axis beam selection, got:\n{result.stdout}"
        )

    def test_reports_fractional_delay_accuracy(self):
        """Fractional delay filters should have < 0.5 dB gain error."""
        _ensure_built()
        test_binary = BUILD_DIR / "test_array_frontend"
        result = subprocess.run(
            [str(test_binary)],
            capture_output=True, text=True, timeout=60,
        )
        # Parse worst gain error from output line like:
        # "worst |gain error| 0.210 dB"
        for line in result.stdout.splitlines():
            if "worst |gain error|" in line:
                # Extract the numeric value
                parts = line.split()
                idx = parts.index("|gain")
                val = float(parts[idx + 2].replace("dB", ""))
                assert val < 0.5, f"Gain error too large: {val} dB"
                return
        pytest.fail("Could not find fractional delay gain error in output")

    def test_reports_das_model_deviation(self):
        """DAS beam should deviate < 1 dB from analytical model."""
        _ensure_built()
        test_binary = BUILD_DIR / "test_array_frontend"
        result = subprocess.run(
            [str(test_binary)],
            capture_output=True, text=True, timeout=60,
        )
        for line in result.stdout.splitlines():
            if "deviation from DAS model" in line:
                parts = line.split()
                idx = parts.index("worst")
                val = float(parts[idx + 1].replace("dB", ""))
                assert val < 1.0, f"DAS deviation too large: {val} dB"
                return
        pytest.fail("Could not find DAS model deviation in output")
