# Packages `dictation-tray` (the AppIndicator/SNI status daemon). A PyGObject app, so the real
# work is the runtime GI environment: wrapGAppsHook3 + gobject-introspection collect the typelibs
# from gtk3 + libayatana-appindicator into GI_TYPELIB_PATH so `gi.require_version(...)` resolves.
{ stdenvNoCC
, lib
, python3
, gtk3
, gobject-introspection
, libayatana-appindicator
, wrapGAppsHook3
}:
let
  py = python3.withPackages (ps: [ ps.pygobject3 ]);
in
stdenvNoCC.mkDerivation {
  pname = "dictation-tray";
  version = "0.1";
  src = ../tray;

  nativeBuildInputs = [ wrapGAppsHook3 gobject-introspection ];
  buildInputs = [ py gtk3 libayatana-appindicator ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 dictation-tray.py $out/bin/dictation-tray
    # Pin the interpreter to the pygobject3 env (not whatever python is first on PATH).
    substituteInPlace $out/bin/dictation-tray \
      --replace '#!/usr/bin/env python3' '#!${py}/bin/python3'
    runHook postInstall
  '';

  meta = {
    description = "System-tray status + control for the local dictation tool (AppIndicator/SNI)";
    mainProgram = "dictation-tray";
    platforms = lib.platforms.linux;
  };
}
