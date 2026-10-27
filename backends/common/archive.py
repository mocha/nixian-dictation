"""Server-side archive of every transcription request (audio as uploaded + transcript + metadata).

Shared by both backends. Lands in the same folder the keybind client archives to by default, so
the existing prune/NAS-backup timers cover API traffic too. The keybind client keeps its own
archive (it saves audio before the POST, stores dictionary-corrected text, and handles streaming)
and opts out per request with `archive=0`; every other caller -- OpenWhispr, scripts -- is archived
here. Archiving never fails a request: errors are logged and the transcript is still returned.

Env: WHISPER_ARCHIVE_DIR (default ~/Recordings/Dictation; "off" or empty disables).
Files: <dir>/dictation-YYYYMMDD-HHMMSS-<4 hex>.{<audio ext>,txt,json}
"""
import json
import logging
import os
import secrets
import time

logger = logging.getLogger(__name__)

ARCHIVE_DIR = os.environ.get("WHISPER_ARCHIVE_DIR",
                             os.path.join(os.path.expanduser("~"), "Recordings", "Dictation"))
ENABLED = ARCHIVE_DIR not in ("", "off", "0")

# Magic-byte sniffing for a raw body with no filename; (offset, bytes, extension).
_MAGIC = [(0, b"RIFF", "wav"), (0, b"fLaC", "flac"), (0, b"OggS", "ogg"), (0, b"ID3", "mp3"),
          (0, b"\xff\xfb", "mp3"), (0, b"\xff\xf3", "mp3"), (4, b"ftyp", "m4a"),
          (0, b"\x1a\x45\xdf\xa3", "webm")]


def _ext(data, filename):
    if filename and "." in filename:
        ext = filename.rsplit(".", 1)[1].lower()
        if ext.isalnum() and len(ext) <= 5:
            return ext
    for off, magic, ext in _MAGIC:
        if data[off:off + len(magic)] == magic:
            return ext
    return "audio"


def start(data, filename=None, meta=None, wanted=True):
    """Save the uploaded audio before transcription (so a failure keeps it). Returns a record for
    finish(), or None when archiving is off/opted out/failed."""
    if not (ENABLED and wanted):
        return None
    try:
        os.makedirs(ARCHIVE_DIR, exist_ok=True)
        base = os.path.join(ARCHIVE_DIR, time.strftime("dictation-%Y%m%d-%H%M%S-")
                            + secrets.token_hex(2))
        path = f"{base}.{_ext(data, filename)}"
        with open(path, "wb") as f:
            f.write(data)
        return {"base": base, "audio": os.path.basename(path), "t0": time.time(),
                "meta": dict(meta or {}, received=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                             bytes=len(data), filename=filename)}
    except Exception as e:
        logger.error("archive: could not save audio: %s", e)
        return None


def finish(rec, result=None, error=None):
    """Write the transcript (.txt; a bracketed failure note on error) and metadata (.json)."""
    if rec is None:
        return
    try:
        text = result["text"] if result else f"[no transcript — {error}]"
        with open(rec["base"] + ".txt", "w") as f:
            f.write(text + "\n")
        meta = dict(rec["meta"], audio=rec["audio"], elapsed_s=round(time.time() - rec["t0"], 2),
                    error=error)
        if result:
            meta.update(mode=result.get("mode"), speakers=result.get("speakers"))
        with open(rec["base"] + ".json", "w") as f:
            json.dump(meta, f, indent=1)
    except Exception as e:
        logger.error("archive: could not save transcript for %s: %s", rec["base"], e)


def wanted(value):
    """Per-request opt-out: archive=0|false|no|off (query string or form field)."""
    return str(value).lower() not in ("0", "false", "no", "off")


def run(data, transcribe, filename=None, meta=None, wanted=True):
    """Archive around one transcription: save audio, call transcribe() -> result dict, record the
    transcript or the error (then re-raise). Adds result["archived"] = audio filename when saved."""
    rec = start(data, filename, meta, wanted)
    try:
        result = transcribe()
    except Exception as e:
        finish(rec, error=str(e))
        raise
    finish(rec, result=result)
    if rec:
        result["archived"] = rec["audio"]
    return result
