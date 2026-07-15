# faster-whisper (CTranslate2 + CUDA) Python env for the cuda-local backend server.
#
# Scoped CUDA override: only ctranslate2 is rebuilt `withCUDA` (+cuDNN); nothing else in the
# system's package set is touched, so no unrelated consumer is forced to rebuild. Kept byte-for-byte
# identical to the one-time pre-warm build (scratchpad fw-cuda.nix) so Nix reuses that store path
# instead of compiling the ~40-min CUDA stack a second time.
#
# Parameterized by `nixpkgs` so module.nix can pass `pkgs.path` (the exact channel the system builds
# from); the default `<nixpkgs>` makes `nix-build nix/whisper-env.nix` produce the same derivation.
{ nixpkgs ? <nixpkgs> }:
let
  pkgs = import nixpkgs {
    config.allowUnfree = true;   # CUDA / cuDNN are unfree
    overlays = [
      (final: prev: {
        ctranslate2 = prev.ctranslate2.override {
          withCUDA = true;
          withCuDNN = true;
        };
      })
    ];
  };
in
pkgs.python3.withPackages (ps: with ps; [ faster-whisper flask waitress ])
