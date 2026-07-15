"""faster-whisper (CTranslate2 / CUDA) transcription server — the `cuda-local` backend.

Speaks the *same* HTTP contract as the NPU backend (`backends/npu/server.py`), so the client
(`dictation-toggle.sh`) is backend-agnostic — only BASE_URL + model name differ per host:

  GET  /health                          -> {requested_device, available_devices, loaded, default}
  GET  /models                          -> {models: [...]}
  POST /warm[/<model>]                  -> {warm, model} | {error}
  POST /transcribe[/<model>]  (raw body)-> {text} | {error}
  POST /v1/audio/transcriptions (mp)    -> OpenAI-compatible {text}

Differences from the NPU/OpenVINO backend (deliberate, same external behaviour):
  - engine is faster-whisper (CTranslate2); on Dynamo that runs on the RTX 4070 Ti via CUDA.
  - model names are faster-whisper IDs (e.g. "small.en", "large-v3", "distil-large-v3") or a
    local path; CTranslate2/HF fetches+caches them under ~/.cache/huggingface, so there is no
    models dir to pre-populate (unlike the NPU IR export OpenVINO needs).
  - silence/hallucination handling is faster-whisper's built-in VAD filter, replacing the
    librosa top-db trim the NPU server did (Whisper's phantom "you"/"thank you" on silence).

Env:
  WHISPER_DEVICE=cuda|cpu|auto   (default cuda)   WHISPER_COMPUTE_TYPE=float16|int8_float16|int8
  WHISPER_DEFAULT_MODEL=small.en                  WHISPER_MODELS=small.en,large-v3  (/models list)
  WHISPER_BEAM_SIZE=5   WHISPER_VAD=1|0   PORT=5000   SERVER_THREADS=4
"""
import io
import os
import logging
import threading

import ctranslate2
from faster_whisper import WhisperModel
from flask import Flask, request, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# A CTranslate2 WhisperModel is not safe to drive from multiple threads at once; serialize all
# model-load + inference (like the NPU backend did). Read-only endpoints (/health, /models) skip
# the lock so they stay responsive while a long transcription — or a first cold model load —
# holds it.
_infer_lock = threading.Lock()

DEVICE = os.environ.get("WHISPER_DEVICE", "cuda")
COMPUTE_TYPE = os.environ.get("WHISPER_COMPUTE_TYPE", "float16")
DEFAULT_MODEL = os.environ.get("WHISPER_DEFAULT_MODEL", "small.en")
# Informational allow-list surfaced by /models. Any valid faster-whisper id still works on
# /transcribe even if not listed here; this is just what the UI/tray would show.
MODELS = [m for m in os.environ.get("WHISPER_MODELS", DEFAULT_MODEL).split(",") if m]
BEAM_SIZE = int(os.environ.get("WHISPER_BEAM_SIZE", "5"))
VAD = os.environ.get("WHISPER_VAD", "1") != "0"


class ModelManager:
    def __init__(self):
        self.pipelines = {}
        self.default_model = DEFAULT_MODEL

    def load_model(self, model_name):
        if model_name not in self.pipelines:
            logger.info("Loading model %s on device=%s (%s)", model_name, DEVICE, COMPUTE_TYPE)
            self.pipelines[model_name] = WhisperModel(
                model_name, device=DEVICE, compute_type=COMPUTE_TYPE
            )
        return self.pipelines[model_name]

    def list_models(self):
        return MODELS


def _transcribe(audio_data, model_name):
    """Decode → VAD-trim → transcribe. faster-whisper decodes the raw body via PyAV and (with
    vad_filter) drops non-speech, so silence doesn't produce phantom tokens. Returns the joined
    transcript string; raises on failure (unknown/failed model load, decode error)."""
    with _infer_lock:
        model = model_manager.load_model(model_name)
        segments, _info = model.transcribe(
            io.BytesIO(audio_data), beam_size=BEAM_SIZE, vad_filter=VAD
        )
        return "".join(seg.text for seg in segments).strip()


def _available_devices():
    """Best-effort device report for /health, so a silent CPU fallback is visible (the CUDA
    analogue of the NPU backend logging available_devices — catches 'built without CUDA')."""
    try:
        n = ctranslate2.get_cuda_device_count()
    except Exception:
        n = 0
    return [f"cuda:{i}" for i in range(n)] + ["cpu"]


@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "requested_device": DEVICE,
        "available_devices": _available_devices(),
        "compute_type": COMPUTE_TYPE,
        "loaded": list(model_manager.pipelines.keys()),
        "default": model_manager.default_model,
    })


@app.route("/models", methods=["GET"])
def list_models():
    return jsonify({"models": model_manager.list_models()})


@app.route("/warm/<model_name>", methods=["POST"])
def warm_model(model_name):
    """Force-load (or confirm loaded) a model with no audio. The client fires this the moment a
    dictation *starts* so a cold model compiles/downloads while the user is still talking, instead
    of the transcribe POST at stop paying that latency."""
    try:
        with _infer_lock:
            model_manager.load_model(model_name)
        return jsonify({"warm": True, "model": model_name})
    except Exception as e:
        logger.error("Error (warm): %s", e)
        return jsonify({"error": str(e)}), 500


@app.route("/warm", methods=["POST"])
def warm_default():
    return warm_model(model_manager.default_model)


@app.route("/transcribe/<model_name>", methods=["POST"])
def transcribe_with_model(model_name):
    try:
        audio_data = request.get_data()
        if not audio_data:
            return jsonify({"error": "No audio data"}), 400
        return jsonify({"text": _transcribe(audio_data, model_name)})
    except Exception as e:
        logger.error("Error: %s", e)
        return jsonify({"error": str(e)}), 500


@app.route("/transcribe", methods=["POST"])
def transcribe():
    return transcribe_with_model(model_manager.default_model)


@app.route("/v1/audio/transcriptions", methods=["POST"])
def openai_transcriptions():
    """OpenAI-compatible: multipart with `file` (audio) + optional `model` / `response_format`
    (json|text|verbose_json). Lets any OpenAI SDK point at this server; an unknown `model`
    (e.g. "whisper-1") falls back to the server default."""
    try:
        f = request.files.get("file")
        if f is None:
            return jsonify({"error": {"message": "missing 'file'", "type": "invalid_request_error"}}), 400
        audio_data = f.read()
        if not audio_data:
            return jsonify({"error": {"message": "empty 'file'", "type": "invalid_request_error"}}), 400
        model_name = request.form.get("model") or model_manager.default_model
        if model_name not in model_manager.list_models():
            model_name = model_manager.default_model
        text = _transcribe(audio_data, model_name)
        fmt = (request.form.get("response_format") or "json").lower()
        if fmt == "text":
            return app.response_class(text, mimetype="text/plain; charset=utf-8")
        if fmt == "verbose_json":
            return jsonify({"task": "transcribe", "text": text})
        return jsonify({"text": text})
    except Exception as e:
        logger.error("Error (v1): %s", e)
        return jsonify({"error": {"message": str(e), "type": "server_error"}}), 500


model_manager = ModelManager()

# Startup diagnostics + best-effort pre-warm. Never crash the server if the model/GPU isn't ready
# — /health then reveals whether CUDA was actually seen (available_devices) vs a silent CPU build.
try:
    logger.info("CTranslate2 CUDA devices=%d; available=%s",
                ctranslate2.get_cuda_device_count(), _available_devices())
except Exception as e:
    logger.error("Could not query CTranslate2 CUDA devices: %s", e)

try:
    model_manager.load_model(model_manager.default_model)
    logger.info("Pre-warmed %s on %s (%s)", model_manager.default_model, DEVICE, COMPUTE_TYPE)
except Exception as e:
    logger.error("Pre-warm of %s on %s failed (server still starting): %s",
                 model_manager.default_model, DEVICE, e)

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5000"))
    threads = int(os.environ.get("SERVER_THREADS", "4"))
    try:
        from waitress import serve
        logger.info("Serving via waitress on 127.0.0.1:%d (threads=%d)", port, threads)
        serve(app, host="127.0.0.1", port=port, threads=threads)
    except ImportError:
        logger.warning("waitress unavailable — falling back to the Flask dev server")
        app.run(host="127.0.0.1", port=port)
