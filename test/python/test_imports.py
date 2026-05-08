"""
Python environment verification tests for the audio-to-gp worker.

These tests ensure all packages required by worker.py are correctly installed
in the venv and that the ONNX model path exists alongside basic-pitch.

Run from the repo root with the app's venv active:

    <toolsDir>/.venv/Scripts/python.exe -m pytest audio_to_gp_flutter/test/python/test_imports.py -v

Or during CI / build validation:

    uv run --python 3.11 pytest audio_to_gp_flutter/test/python/test_imports.py -v
"""

from __future__ import annotations

import importlib
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _import(name: str):
    """Import *name* and return the module (asserts no ImportError)."""
    return importlib.import_module(name)


# ---------------------------------------------------------------------------
# Core runtime
# ---------------------------------------------------------------------------

class TestCoreRuntime:
    def test_python_version(self):
        """Python 3.10–3.11 is required (torch wheels are not yet on 3.12+)."""
        major, minor = sys.version_info[:2]
        assert (major, minor) >= (3, 10), f"Python >=3.10 required, got {major}.{minor}"
        assert (major, minor) <= (3, 11), (
            f"Python <=3.11 recommended for torch wheel compatibility, got {major}.{minor}"
        )

    def test_setuptools_pkg_resources(self):
        """pkg_resources is required by onnxruntime; provided by setuptools."""
        _import("pkg_resources")

    def test_pathlib(self):
        _import("pathlib")

    def test_json(self):
        _import("json")


# ---------------------------------------------------------------------------
# Audio / ML stack
# ---------------------------------------------------------------------------

class TestAudioMLStack:
    def test_torch_importable(self):
        torch = _import("torch")
        assert hasattr(torch, "__version__"), "torch missing __version__"

    def test_torchaudio_importable(self):
        _import("torchaudio")

    def test_soundfile_importable(self):
        _import("soundfile")

    def test_demucs_importable(self):
        _import("demucs")

    def test_basic_pitch_importable(self):
        _import("basic_pitch")

    def test_basic_pitch_inference_importable(self):
        mod = _import("basic_pitch.inference")
        assert hasattr(mod, "predict"), "basic_pitch.inference.predict not found"
        assert hasattr(mod, "Model"), "basic_pitch.inference.Model not found"

    def test_pretty_midi_importable(self):
        _import("pretty_midi")


# ---------------------------------------------------------------------------
# ONNX runtime
# ---------------------------------------------------------------------------

class TestOnnxRuntime:
    def test_onnxruntime_importable(self):
        ort = _import("onnxruntime")
        assert hasattr(ort, "InferenceSession"), "onnxruntime.InferenceSession not found"

    def test_onnxruntime_providers_not_empty(self):
        ort = _import("onnxruntime")
        providers = ort.get_available_providers()
        assert providers, "onnxruntime returned no execution providers"
        assert "CPUExecutionProvider" in providers, (
            f"CPUExecutionProvider missing from {providers}"
        )

    def test_onnxruntime_gpu_provider_when_cuda(self):
        """If torch reports CUDA available, onnxruntime-gpu should also report it."""
        ort = _import("onnxruntime")
        torch = _import("torch")
        if torch.cuda.is_available():
            assert "CUDAExecutionProvider" in ort.get_available_providers(), (
                "torch.cuda.is_available() is True but onnxruntime does not expose "
                "CUDAExecutionProvider — install onnxruntime-gpu instead of onnxruntime"
            )


# ---------------------------------------------------------------------------
# basic-pitch ONNX model path
# ---------------------------------------------------------------------------

class TestBasicPitchModel:
    def test_icassp_model_path_constant_exists(self):
        bp = _import("basic_pitch")
        assert hasattr(bp, "ICASSP_2022_MODEL_PATH"), (
            "basic_pitch.ICASSP_2022_MODEL_PATH not found — "
            "basic-pitch version may be incompatible"
        )

    def test_onnx_model_file_exists(self):
        """The .onnx file must be next to the TF SavedModel directory."""
        bp = _import("basic_pitch")
        tf_path = Path(str(bp.ICASSP_2022_MODEL_PATH))
        onnx_path = Path(str(tf_path) + ".onnx")
        assert onnx_path.exists(), (
            f"ONNX model not found at {onnx_path}. "
            "Expected it next to the TF SavedModel dir. "
            "Reinstall basic-pitch: uv pip install basic-pitch"
        )

    def test_onnx_model_loadable(self):
        """The ONNX session must be creatable with CPUExecutionProvider."""
        import onnxruntime as ort
        from basic_pitch import ICASSP_2022_MODEL_PATH

        onnx_path = Path(str(ICASSP_2022_MODEL_PATH) + ".onnx")
        if not onnx_path.exists():
            # Already caught by the path test above; don't duplicate the error.
            return

        session = ort.InferenceSession(
            str(onnx_path), providers=["CPUExecutionProvider"]
        )
        assert session is not None

    def test_basic_pitch_model_wrapper(self):
        """Verify the Model.__new__ bypass used in worker.py works."""
        import onnxruntime as ort
        from basic_pitch import ICASSP_2022_MODEL_PATH
        from basic_pitch.inference import Model

        onnx_path = Path(str(ICASSP_2022_MODEL_PATH) + ".onnx")
        if not onnx_path.exists():
            return  # path test will report the failure

        bp_model = Model.__new__(Model)
        bp_model.model_type = Model.MODEL_TYPES.ONNX
        bp_model.model = ort.InferenceSession(
            str(onnx_path), providers=["CPUExecutionProvider"]
        )
        assert bp_model.model is not None


# ---------------------------------------------------------------------------
# Torch GPU consistency
# ---------------------------------------------------------------------------

class TestTorchGpu:
    def test_torch_version_acceptable(self):
        import torch

        major, minor, *_ = [int(x) for x in torch.__version__.split(".")[:2]]
        assert major >= 2, f"torch >=2.1 required, got {torch.__version__}"

    def test_cuda_device_name_when_available(self):
        import torch

        if torch.cuda.is_available():
            name = torch.cuda.get_device_name(0)
            assert name, "torch.cuda.is_available() True but device name is empty"
            print(f"\n  CUDA device: {name}")
        else:
            print("\n  No CUDA device — running on CPU")
