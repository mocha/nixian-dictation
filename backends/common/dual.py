"""Two-speaker (dual-lav) segmentation: one speaker per channel of a stereo recording.

Shared by both backends (npu-image/server.py, backends/cuda/server.py): each passes its 16 kHz
(2, n) float audio plus a function that transcribes one mono block; everything else -- detection,
segmentation, pitch-based naming, dedupe, formatting -- lives here. numpy + librosa (pyin) only.

Each lav also picks up the *other* speaker (bleed), often well above its own noise floor, and the
two mics rarely share a gain/noise floor -- so neither "loud" nor "louder than the other channel"
works on raw levels. Instead: over frames where anyone is talking, the L-R level difference is
bimodal (A talking vs B talking); a two-cluster split of it gives the decision threshold with the
gain offset baked in. Each speech frame goes to one speaker. Cross-talk/interjections still survive:
a block keeps running across short gaps (SPLIT_GAP_S) and is transcribed from its own channel over
the whole span, so the main speaker's words under a brief interjection aren't lost.
"""
import difflib
import itertools
import json
import logging

import librosa
import numpy as np

logger = logging.getLogger(__name__)

SR = 16000
HOP = 480                # 30 ms frames
FLOOR_PCT = 10           # per-channel noise floor = this percentile of frame dB
SPEECH_PCT = 99          # per-channel speech level = this percentile of frame dB
ACTIVE_FRAC = 0.4        # frame is "loud" above floor + this fraction of the floor→speech range
ACTIVE_MIN_DB = 12.0     # ...but never less than this above the floor
SMOOTH_FRAMES = 7        # ~200 ms moving average on frame dB before deciding anything
MIN_SEPARATION_DB = 10.0 # A-talking vs B-talking L-R clusters must be this far apart to call it dual
MIN_SHARE = 0.05         # and each speaker must hold at least this share of the speech frames
SPLIT_GAP_S = 1.5        # silence this long ends a block ("pause"); 0.8 split walking speech mid-sentence
MIN_VOICED_S = 0.25      # blocks with less voiced audio than this are dropped (clicks, breaths)
PAD_S = 0.2              # context added either side of a block before transcription
# Whisper's stock output for a short block of breath/rustle/bleed. Dropped only when the whole block
# is shorter than PHANTOM_MAX_S, so a real "thank you" inside actual speech survives.
PHANTOMS = {"you", "thank you", "thanks", "thank you very much", "bye", "okay"}
PHANTOM_MAX_S = 2.0
# Voice naming (see name_speakers): pitch is measured on a speaker's longest blocks, up to this much audio.
PITCH_MAX_S = 60.0
PITCH_BLOCK_MAX_S = 10.0  # ...taking at most this much from each, so one long monologue can't use it all
PITCH_MIN_RATIO = 1.15   # channels' median pitches must differ by at least this factor to name them
PITCH_TOLERANCE = 1.3    # and each must be within this factor of its assigned profile (raised voice
                         # outdoors moved one speaker ~100 → ~150 Hz; set profiles near the middle)


def _frame_db(x):
    n = len(x) // HOP
    f = x[: n * HOP].reshape(n, HOP).astype(np.float64)
    db = 10 * np.log10(np.mean(f * f, axis=1) + 1e-10)
    return np.convolve(db, np.ones(SMOOTH_FRAMES) / SMOOTH_FRAMES, "same")


def _loud(db):
    floor = np.percentile(db, FLOOR_PCT)
    span = np.percentile(db, SPEECH_PCT) - floor
    return db > floor + max(ACTIVE_MIN_DB, ACTIVE_FRAC * span)


def _two_means(x, iters=20):
    """1-D k-means with k=2 → (low centre, high centre, threshold, share of points above it)."""
    lo, hi = np.percentile(x, 10), np.percentile(x, 90)
    for _ in range(iters):
        t = (lo + hi) / 2
        if not (x > t).any() or (x > t).all():
            break
        lo, hi = x[x <= t].mean(), x[x > t].mean()
    t = (lo + hi) / 2
    return float(lo), float(hi), float(t), float((x > t).mean())


def analyze(left, right):
    """Return (is_dual, info). info carries per-frame activity for segment() plus diagnostics."""
    dl, dr = _frame_db(left), _frame_db(right)
    speech = _loud(dl) | _loud(dr)
    info = {"frames": len(dl), "speech_frames": int(speech.sum())}
    if speech.sum() < 10:
        return False, info
    d = dl - dr
    lo, hi, thresh, share_a = _two_means(d[speech])
    n = len(dl) * HOP
    corr = float(np.corrcoef(left[:n], right[:n])[0, 1])
    info.update(sep_db=hi - lo, thresh_db=thresh, share_a=share_a, corr=corr)
    if hi - lo < MIN_SEPARATION_DB or min(share_a, 1 - share_a) < MIN_SHARE or corr > 0.9:
        return False, info
    info["act_a"] = speech & (d > thresh)
    info["act_b"] = speech & (d <= thresh)
    return True, info


def _blocks(active, n_samples):
    gap = int(SPLIT_GAP_S * SR / HOP)
    idx = np.flatnonzero(active)
    if idx.size == 0:
        return []
    runs, start, prev = [], idx[0], idx[0]
    for i in idx[1:]:
        if i - prev > gap:
            runs.append((start, prev))
            start = i
        prev = i
    runs.append((start, prev))
    pad = int(PAD_S * SR)
    out = []
    for s, e in runs:
        if active[s : e + 1].sum() * HOP < MIN_VOICED_S * SR:
            continue
        out.append((max(0, s * HOP - pad), min(n_samples, (e + 1) * HOP + pad),
                    int(active[s : e + 1].sum())))
    return out


def segment(info, n_samples):
    """[(start_sample, end_sample, speaker, voiced_frames)] for both speakers, sorted by start."""
    blocks = [(s, e, "A", v) for s, e, v in _blocks(info["act_a"], n_samples)]
    blocks += [(s, e, "B", v) for s, e, v in _blocks(info["act_b"], n_samples)]
    return sorted(blocks)


def dedupe(segments):
    """Drop cross-channel duplicates: a loud voice (shouting, someone calling out) can flip frame
    assignment back and forth, so both channels transcribe the same words over the same span. Of a
    time-overlapping A/B pair with near-identical text, keep the one with more voiced frames."""
    drop = set()
    for i, a in enumerate(segments):
        for j in range(i + 1, len(segments)):
            b = segments[j]
            if b["start"] >= a["end"]:
                break
            if a["speaker"] == b["speaker"]:
                continue
            ratio = difflib.SequenceMatcher(None, a["text"].lower(), b["text"].lower()).ratio()
            if ratio > 0.6:
                drop.add(j if a["voiced"] >= b["voiced"] else i)
    return [g for k, g in enumerate(segments) if k not in drop]


def median_pitch(channel, blocks, active):
    """Median over a speaker's longest blocks of each block's median F0 (Hz), or None if too little
    was voiced. pyin needs contiguous audio (spliced 30 ms frames read badly high), so whole blocks
    are tracked, but only F0 frames inside this speaker's active frames count: block padding and
    bridged gaps carry the other voice's bleed, which otherwise drags the estimate toward it."""
    meds, total = [], 0.0
    for s, e, *_ in sorted(blocks, key=lambda b: b[0] - b[1]):
        if total >= PITCH_MAX_S:
            break
        e = min(e, s + int(PITCH_BLOCK_MAX_S * SR))
        f0, voiced, _ = librosa.pyin(channel[s:e], fmin=60, fmax=400, sr=SR,
                                     frame_length=1024, hop_length=256)
        own = active[np.minimum((s + np.arange(len(f0)) * 256) // HOP, len(active) - 1)]
        f = f0[voiced & own]
        if f.size >= 20:
            meds.append(np.median(f))
        total += (e - s) / SR
    return float(np.median(meds)) if meds else None


def name_speakers(audio, blocks, info, voices):
    """Map channel labels A/B to names from voices ({name: median Hz}) by pitch. Returns
    ({"A": name, "B": name}, diagnostics), or (None, diagnostics) when it can't tell confidently:
    fewer than two profiles, too little speech, voices too alike, or no profile close enough."""
    hz = {k: median_pitch(audio[i], [b for b in blocks if b[2] == k], info["act_" + k.lower()])
          for i, k in enumerate("AB")}
    diag = {"pitch_hz": hz}
    if len(voices) < 2 or None in hz.values():
        return None, diag
    if max(hz.values()) / min(hz.values()) < PITCH_MIN_RATIO:
        return None, diag
    # Best pairing of two distinct profiles to (A, B), by total log-distance in pitch.
    cost, na, nb = min(
        (abs(np.log(hz["A"] / voices[a])) + abs(np.log(hz["B"] / voices[b])), a, b)
        for a, b in itertools.permutations(voices, 2))
    if max(hz["A"] / voices[na], voices[na] / hz["A"],
           hz["B"] / voices[nb], voices[nb] / hz["B"]) > PITCH_TOLERANCE:
        return None, diag
    return {"A": na, "B": nb}, diag


def is_phantom(text, seconds):
    return seconds < PHANTOM_MAX_S and text.lower().strip(" .!?,") in PHANTOMS


def stamp(seconds):
    s = int(seconds)
    h, m, s = s // 3600, s % 3600 // 60, s % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def load_voices(path):
    """{"Name": median_pitch_hz, ...} from a JSON file; {} if missing or unreadable. Re-read per
    request so it can be edited without restarting the server."""
    try:
        with open(path) as f:
            return {str(k): float(v) for k, v in json.load(f).items()}
    except FileNotFoundError:
        return {}
    except Exception as e:
        logger.error("Ignoring unreadable voices file %s: %s", path, e)
        return {}


def detect(audio, speakers):
    """info for transcribe() if `audio` ((2, n) stereo) carries two separate speakers and
    `speakers` is "auto", else None (caller downmixes and transcribes as mono)."""
    if speakers != "auto" or audio.ndim != 2 or audio.shape[0] != 2:
        return None
    is_dual, info = analyze(audio[0], audio[1])
    logger.info("dual check: %s %s", is_dual, {k: v for k, v in info.items() if not k.startswith("act_")})
    return info if is_dual else None


def transcribe(audio, info, transcribe_block, voices):
    """Two-speaker transcript. transcribe_block(mono float32 array) -> str is the backend's
    Whisper call (it takes its own inference lock, so other requests can interleave between
    blocks). Returns {"text", "mode": "dual", "segments", "speakers"}."""
    blocks = segment(info, audio.shape[1])
    names, diag = name_speakers(audio, blocks, info, voices)
    logger.info("speaker naming: %s %s", names, diag)
    names = names or {"A": "A", "B": "B"}
    segments = []
    for start, end, spk, voiced in blocks:
        text = transcribe_block(np.ascontiguousarray(audio[0 if spk == "A" else 1, start:end])).strip()
        if text and not is_phantom(text, (end - start) / SR):
            segments.append({"start": start / SR, "end": end / SR,
                             "speaker": names[spk], "text": text, "voiced": voiced})
    segments = dedupe(segments)
    lines = [f"[{stamp(g['start'])}][{g['speaker']}] {g['text']}" for g in segments]
    return {"text": "\n".join(lines), "mode": "dual", "segments": segments, "speakers": names}


def openai_segments(result):
    """verbose_json `segments` for a two-speaker result (OpenAI shape plus `speaker`)."""
    return [{"id": i, "start": g["start"], "end": g["end"], "speaker": g["speaker"], "text": g["text"]}
            for i, g in enumerate(result["segments"])]
