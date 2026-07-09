"""Whisper transcription server (OpenVINO GenAI), vendored + hardened from the archived
mecattaf/whisper-npu-server so we can rebuild against a Panther-Lake-capable NPU stack.

Changes from upstream:
  - device + default model are env-configurable (WHISPER_DEVICE, WHISPER_DEFAULT_MODEL)
  - logs openvino.Core().available_devices at startup (so `podman logs` proves NPU is seen)
  - startup pre-warm is wrapped so the server still answers /health and /models even if the
    NPU/model fails to load (makes diagnosis possible instead of a crash-loop)
  - adds GET /health -> {devices, loaded, default, requested_device}
  - adds POST /v1/audio/transcriptions (OpenAI-compatible: multipart `file` + `model` +
    `response_format`) so any OpenAI SDK/tool can drive this NPU server
  - adds POST /warm[/<model>]: force-load a model with no audio, so a client can trigger the
    (~30s cold) compile ahead of the real transcribe call instead of eating that latency at it
  - inference is serialized by a lock (one NPU WhisperPipeline can't run concurrent generate()s)
    and served by waitress with worker threads, so /health stays responsive even while a slow
    model-load or transcription holds the lock
API: POST /transcribe[/<model>] with a RAW audio body -> {"text": ...} | {"error": ...}
     POST /v1/audio/transcriptions (multipart) -> OpenAI transcription response
     POST /warm[/<model>] -> {"warm": true, "model": ...} | {"error": ...}
"""
import io
import os
import logging
import threading
from pathlib import Path

import librosa
import openvino
import openvino_genai
from flask import Flask, request, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# One NPU WhisperPipeline is NOT safe for concurrent generate() (returns "Infer Request is busy"),
# so all model-load + inference is serialized here. Read-only endpoints (/health, /models) skip the
# lock, so they stay responsive even while a long transcription — or an 11-min large-model compile —
# holds it. That's the guard the single-threaded dev server lacked (one stray request wedged all).
_infer_lock = threading.Lock()

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


def _transcribe(audio_data, model_name):
    """Decode → trim silence → transcribe. librosa decode/trim runs lock-free (CPU); only the
    NPU model-load + generate() is serialized under _infer_lock. Returns the transcript string;
    raises FileNotFoundError for an unknown model, other exceptions on failure."""
    speech, _ = librosa.load(io.BytesIO(audio_data), sr=16000)
    if TRIM_TOP_DB > 0 and speech.size:
        trimmed, _ = librosa.effects.trim(speech, top_db=TRIM_TOP_DB)
        if trimmed.size:  # keep the trim only if it left actual audio (not an all-silent clip)
            speech = trimmed
    with _infer_lock:
        pipeline = model_manager.load_model(model_name)
        return str(pipeline.generate(speech))


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


@app.route("/warm/<model_name>", methods=["POST"])
def warm_model(model_name):
    """Force-load (or confirm already-loaded) a model without transcribing anything. Callers fire
    this the moment a dictation *starts* so a cold pipeline (first call after boot, or after an
    NPU-resetting suspend/resume) compiles while the user is still talking, instead of the
    transcribe POST at stop paying that cost."""
    try:
        with _infer_lock:
            model_manager.load_model(model_name)
        return jsonify({"warm": True, "model": model_name})
    except FileNotFoundError as e:
        return jsonify({"error": str(e)}), 404
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
    except FileNotFoundError as e:
        return jsonify({"error": str(e)}), 404
    except Exception as e:
        logger.error("Error: %s", e)
        return jsonify({"error": str(e)}), 500


@app.route("/transcribe", methods=["POST"])
def transcribe():
    return transcribe_with_model(model_manager.default_model)


@app.route("/v1/audio/transcriptions", methods=["POST"])
def openai_transcriptions():
    """OpenAI-compatible endpoint: multipart/form-data with `file` (audio) and optional `model`
    and `response_format` (json|text|verbose_json). Lets any OpenAI SDK/tool point straight at the
    NPU server. `model` maps to a local model dir; an unknown/omitted value (e.g. OpenAI's
    "whisper-1") falls back to the server default."""
    try:
        f = request.files.get("file")
        if f is None:
            return jsonify({"error": {"message": "missing 'file'", "type": "invalid_request_error"}}), 400
        audio_data = f.read()
        if not audio_data:
            return jsonify({"error": {"message": "empty 'file'", "type": "invalid_request_error"}}), 400
        model_name = request.form.get("model") or model_manager.default_model
        if model_name not in model_manager.list_models():
            model_name = model_manager.default_model  # accept whisper-1 etc. → our default
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
    port = int(os.environ.get("PORT", "5000"))
    threads = int(os.environ.get("SERVER_THREADS", "4"))
    try:
        from waitress import serve
        logger.info("Serving via waitress on 0.0.0.0:%d (threads=%d)", port, threads)
        serve(app, host="0.0.0.0", port=port, threads=threads)
    except ImportError:
        logger.warning("waitress unavailable — falling back to the Flask dev server (single-threaded)")
        app.run(host="0.0.0.0", port=port)
