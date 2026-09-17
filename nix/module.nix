# NixOS module: `services.dictation` — the declarative seam where a host picks its combination
# (backend + desktop + model) and gets the transcription server + toggle client wired up.
#
#   imports = [ "${dictationSrc}/nix/module.nix" ];
#   services.dictation = { enable = true; desktop = "kde"; backend = "cuda-local"; model = "small.en"; };
#
# Nixian keeps its imperative NPU stack for now; this module implements the `cuda-local`
# (faster-whisper on the GPU) backend used on Dynamo.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.dictation;
  # faster-whisper + CUDA env, scoped so only ctranslate2 rebuilds withCUDA (see whisper-env.nix).
  # `pkgs.path` pins it to the exact channel the system builds from, so the store path matches the
  # one-time pre-warm build instead of recompiling the CUDA stack.
  whisperEnv = import ./whisper-env.nix { nixpkgs = pkgs.path; };
  serverPy = ../backends/cuda/server.py;
  allModels = lib.unique ([ cfg.model ] ++ cfg.models);
in
{
  options.services.dictation = {
    enable = lib.mkEnableOption "local push-to-talk dictation (transcription server + toggle client)";

    desktop = lib.mkOption {
      type = lib.types.enum [ "hyprland" "kde" ];
      description = "Desktop adapter for focused-window detection + paste chord: hyprland (hyprctl/wtype) or kde (kdotool/dotool).";
    };

    backend = lib.mkOption {
      type = lib.types.enum [ "cuda-local" ];
      default = "cuda-local";
      description = "Transcription backend. Only cuda-local (faster-whisper on the GPU) is wired by this module.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "small.en";
      description = "Default faster-whisper model id (e.g. small.en, distil-large-v3, large-v3). Downloaded+cached on first use.";
    };

    models = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra models advertised via /models. The default `model` is always included.";
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "cuda";
      description = "CTranslate2 device: cuda | cpu | auto.";
    };

    computeType = lib.mkOption {
      type = lib.types.str;
      default = "float16";
      description = "CTranslate2 compute type: float16 | int8_float16 | int8 | float32.";
    };

    wrap = lib.mkOption {
      type = lib.types.enum [ "auto" "always" "never" ];
      default = "auto";
      description = "Default <dictation> provenance wrapping: auto (wrap terminal/agent targets), always, or never. Overridable per-run via DICTATION_WRAP.";
    };

    tray = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the system-tray status daemon (AppIndicator/SNI) as a graphical-session --user service.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8009;
      description = "TCP port the server binds and the client posts to.";
    };

    bind = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "*";
      description = ''
        Address the server binds. Loopback by default: nothing in the transcription API
        authenticates, so on a single-user desktop the toggle client should be its only caller.

        Set this to "*" (every interface, IPv4 and IPv6) to let other machines reach it - e.g.
        pointing a laptop's dictation client at the OpenAI-compatible POST
        /v1/audio/transcriptions endpoint. That also means anyone who can reach the port can
        spend your GPU on their audio and read the transcript back, so open it only to a network
        you trust, via `openFirewall` rather than a blanket rule.

        Prefer "*" over "0.0.0.0" if clients reach this host by name rather than by address:
        0.0.0.0 is IPv4-only, so a hostname that also resolves to an AAAA record will send
        IPv6-preferring clients to an address nothing is listening on.

        The toggle client keeps posting to 127.0.0.1, which both "*" and "0.0.0.0" still serve.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open `port` in the system firewall. Only meaningful alongside a non-loopback `bind`;
        setting it without one is an assertion failure rather than a silent no-op.
      '';
    };

    serverUnit = lib.mkOption {
      type = lib.types.str;
      default = "dictation-whisper";
      internal = true;
      description = "systemd --user unit name for the server (the client checks it is active before recording).";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {
        inherit (cfg) desktop model port serverUnit;
        wrapMode = cfg.wrap;
      };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { inherit desktop model port serverUnit; wrapMode = cfg.wrap; }";
      description = "The dictation-toggle client, built for the selected desktop with per-host defaults baked in.";
    };

    trayPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./tray.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./tray.nix { }";
      description = "The dictation-tray (AppIndicator/SNI status daemon) package.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.backend == "cuda-local";
      message = "services.dictation: only backend = \"cuda-local\" is implemented by this module.";
    } {
      assertion = !cfg.openFirewall || !(builtins.elem cfg.bind [ "127.0.0.1" "::1" "localhost" ]);
      message = "services.dictation: openFirewall = true needs a non-loopback bind (e.g. bind = \"*\"); otherwise the port is opened while nothing listens on it.";
    }];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.user.services.${cfg.serverUnit} = {
      description = "Dictation transcription server (faster-whisper, ${cfg.device}/${cfg.computeType})";
      wantedBy = [ "default.target" ];
      environment = {
        WHISPER_DEVICE = cfg.device;
        WHISPER_COMPUTE_TYPE = cfg.computeType;
        WHISPER_DEFAULT_MODEL = cfg.model;
        WHISPER_MODELS = lib.concatStringsSep "," allModels;
        PORT = toString cfg.port;
        HOST = cfg.bind;
        # libcuda.so.1 comes from the NVIDIA *driver* (impure) — not in the nix closure — so it
        # has to be found at /run/opengl-driver/lib. Everything else (cudart, cublas, cuDNN) is
        # RPATH'd from the nix CUDA packages ctranslate2 links.
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
        HF_HOME = "%h/.cache/huggingface";
      };
      serviceConfig = {
        ExecStart = "${whisperEnv}/bin/python ${serverPy}";
        Restart = "on-failure";
        RestartSec = "5";
      };
    };

    systemd.user.services.dictation-tray = lib.mkIf cfg.tray {
      description = "Dictation system-tray status + control (AppIndicator/SNI)";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      environment = {
        DICTATION_SERVER_UNIT = cfg.serverUnit;
        DICTATION_TOGGLE_CMD = "${cfg.package}/bin/dictation-toggle";
      };
      serviceConfig = {
        ExecStart = "${cfg.trayPackage}/bin/dictation-tray";
        Restart = "on-failure";
        RestartSec = "5";
      };
    };

    environment.systemPackages = [ cfg.package ] ++ lib.optional cfg.tray cfg.trayPackage;
  };
}
