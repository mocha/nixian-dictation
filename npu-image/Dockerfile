# Whisper-on-NPU server for Intel Panther Lake (Core Ultra 7 356H, NPU 8086:B03E).
#
# The archived mecattaf image bundled OpenVINO 2024.6 + linux-npu-driver 1.10 — too old to
# enumerate Panther Lake (available_devices == ['CPU'] only). This rebuilds the same tiny
# Flask server against the first PTL-capable stack:
#   - linux-npu-driver v1.28.0 (Dec 2025, "Panther Lake support added"), Ubuntu 24.04 debs
#   - OpenVINO + GenAI 2026.2.1 (Core Ultra Series 3 supported; NPU = static Whisper pipeline)
#   - level-zero loader (libze1) — mandatory, the usual "NPU plugin won't load" cause
# Host provides the intel_vpu KMD + vpu_50xx firmware; container only needs the UMD+compiler.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# NOTE: do NOT install Ubuntu's libze1 (it's 1.16, too old to load the 1.28 NPU driver →
# NPU won't enumerate). The level-zero loader comes from oneapi-src below instead.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl python3 python3-pip \
        libtbb12 libtbbbind-2-5 libhwloc15 \
    && rm -rf /var/lib/apt/lists/*

# Intel NPU user-mode driver + compiler (v1.28.0 = first Panther Lake release). The release
# attaches a single tarball; the .debs are inside it. intel-fw-npu is host firmware (already
# loaded on the host) so it's intentionally omitted.
# NOTE: run apt from a dedicated dir (not /tmp) and force the apt sandbox user to root —
# otherwise apt's unprivileged _apt user can't create its GPG temp file in the CWD and the
# local debs fail with a bogus "repository is not signed" error.
# level-zero loader v1.30.0 (oneapi-src) — REQUIRED: Ubuntu's 1.16 loader can't load the
# 1.28 NPU driver. Installed together with the NPU debs so apt resolves deps in one shot.
RUN mkdir -p /opt/npu && cd /opt/npu \
 && curl -fSL -o npu.tar.gz \
      "https://github.com/intel/linux-npu-driver/releases/download/v1.28.0/linux-npu-driver-v1.28.0.20251218-20347000698-ubuntu2404.tar.gz" \
 && tar xf npu.tar.gz \
 && curl -fSL -o libze1.deb \
      "https://github.com/oneapi-src/level-zero/releases/download/v1.30.0/libze1_1.30.0%2Bu24.04_amd64.deb" \
 && apt-get -o APT::Sandbox::User=root update \
 && apt-get -o APT::Sandbox::User=root install -y --no-install-recommends \
      ./libze1.deb \
      $(find . -name 'intel-driver-compiler-npu_*_ubuntu24.04_amd64.deb' -o -name 'intel-level-zero-npu_*_ubuntu24.04_amd64.deb') \
 && cd / && rm -rf /opt/npu /var/lib/apt/lists/*

# OpenVINO + GenAI (versions MUST match; genai is 4-part) + server deps.
RUN pip install --break-system-packages --no-cache-dir \
        openvino==2026.2.1 openvino-tokenizers==2026.2.1 openvino-genai==2026.2.1.0 \
        flask librosa soundfile

# Default model the server pre-warms on the NPU at startup (must be a current OpenVINO
# export — 2024-era IR fails the static NPU pipeline). The toggle script requests this same
# name via /transcribe/<model>, so the first real dictation is instant.
ENV WHISPER_DEVICE=NPU \
    WHISPER_DEFAULT_MODEL=whisper-small.en-fp16-ov

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 5000
CMD ["python3", "/app/server.py"]
