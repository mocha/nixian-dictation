"""Whisper transcription server (OpenVINO GenAI), vendored + hardened from the archived
mecattaf/whisper-npu-server so we can rebuild against a Panther-Lake-capable NPU stack.

Changes from upstream:
  - device + default model are env-configurable (WHISPER_DEVICE, WHISPER_DEFAULT_MODEL)
  - logs openvino.Core().available_devices at startup (so `podman logs` proves NPU is seen)
  - startup pre-warm is wrapped so the server still answers /health and /models even if the
    NPU/model fails to load (makes diagnosis possible instead of a crash-loop)
  - adds GET /health -> {devices, loaded, default, requested_device}
API (unchanged): POST /transcribe[/<model>] with a RAW audio body -> {"text": ...} | {"error": ...}
"""
import io
import os
import logging
from pathlib import Path

import librosa
import openvino
import openvino_genai
from flask import Flask, request, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

DEVICE = os.environ.get("WHISPER_DEVICE", "NPU")
# Trim leading/trailing silence before inference: Whisper emits phantom tokens on silence
# (the classic "you"/"thank you" hallucinations) and transcribing it wastes NPU time. top_db is
# the librosa threshold (dB below peak) treated as silence; WHISPER_TRIM_TOP_DB=0 disables it.
TRIM_TOP_DB = int(os.environ.get("WHISPER_TRIM_TOP_DB", "35"))


class ModelManager:
    def __init__(self):
        self.models_dir = os.path.join(os.path.expanduser("~"), ".whisper", "models")
        self.pipelines = {}
        self.default_model = os.environ.get("WHISPER_DEFAULT_MODEL", "whisper-small")
        os.makedirs(self.models_dir, exist_ok=True)

    def load_model(self, model_name):
        if model_name not in self.pipelines:
            model_path = Path(self.models_dir) / model_name
            if not model_path.exists():
                raise FileNotFoundError(f"Model {model_name} not found")
            logger.info("Loading model %s on device=%s", model_name, DEVICE)
            # NPU requires the static-shape Whisper pipeline; fall back if the kwarg name
            # differs across openvino-genai versions.
            kwargs = {"STATIC_PIPELINE": True} if DEVICE == "NPU" else {}
            try:
                self.pipelines[model_name] = openvino_genai.WhisperPipeline(str(model_path), DEVICE, **kwargs)
            except TypeError:
                self.pipelines[model_name] = openvino_genai.WhisperPipeline(str(model_path), DEVICE)
        return self.pipelines[model_name]

    def list_models(self):
        return [d for d in os.listdir(self.models_dir)
                if os.path.isdir(os.path.join(self.models_dir, d))]


@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "requested_device": DEVICE,
        "available_devices": openvino.Core().available_devices,
        "loaded": list(model_manager.pipelines.keys()),
        "default": model_manager.default_model,
    })


@app.route("/models", methods=["GET"])
def list_models():
    return jsonify({"models": model_manager.list_models()})


@app.route("/transcribe/<model_name>", methods=["POST"])
def transcribe_with_model(model_name):
    try:
        pipeline = model_manager.load_model(model_name)
        audio_data = request.get_data()
        if not audio_data:
            return jsonify({"error": "No audio data"}), 400
        speech, _ = librosa.load(io.BytesIO(audio_data), sr=16000)
        if TRIM_TOP_DB > 0 and speech.size:
            trimmed, _ = librosa.effects.trim(speech, top_db=TRIM_TOP_DB)
            if trimmed.size:  # keep the trim only if it left actual audio (not an all-silent clip)
                speech = trimmed
        result = pipeline.generate(speech)
        return jsonify({"text": str(result)})
    except Exception as e:
        logger.error("Error: %s", e)
        return jsonify({"error": str(e)}), 500


@app.route("/transcribe", methods=["POST"])
def transcribe():
    return transcribe_with_model(model_manager.default_model)


model_manager = ModelManager()

# Startup diagnostics + best-effort pre-warm (do NOT crash the server if the NPU isn't ready;
# /health will then reveal whether NPU was enumerated).
try:
    logger.info("OpenVINO %s; available_devices=%s",
                openvino.__version__, openvino.Core().available_devices)
except Exception as e:
    logger.error("Could not query OpenVINO devices: %s", e)

try:
    model_manager.load_model(model_manager.default_model)
    logger.info("Pre-warmed %s on %s", model_manager.default_model, DEVICE)
except Exception as e:
    logger.error("Pre-warm of %s on %s failed (server still starting): %s",
                 model_manager.default_model, DEVICE, e)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "5000")))
