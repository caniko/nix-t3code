{
  pkgs,
  manifest,
  runtimePackages ? [ ],
}:
let
  inherit (pkgs)
    appimageTools
    fetchurl
    lib
    makeWrapper
    stdenvNoCC
    ;
  inherit (manifest) version;
  inherit (manifest.assets) cli desktop;

  fetch =
    asset:
    fetchurl {
      inherit (asset) url;
      hash =
        asset.hash or (builtins.convertHash {
          hash = "sha256:${asset.sha256}";
          toHashFormat = "sri";
        });
    };
  pathArgs = lib.optionalString (runtimePackages != [ ]) (
    "--prefix PATH : ${lib.escapeShellArg (lib.makeBinPath runtimePackages)}"
  );
  meta = {
    homepage = "https://t3.codes";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };

  desktopArgs = {
    pname = "t3code-desktop";
    inherit version;
    src = fetch desktop;
  };
  desktopUnwrapped = appimageTools.wrapType2 (
    desktopArgs
    // {
      extraPkgs = _: runtimePackages;
    }
  );
  desktopExtracted = appimageTools.extract desktopArgs;
  desktopPackage = stdenvNoCC.mkDerivation {
    pname = "t3code-desktop-nightly";
    inherit version;
    nativeBuildInputs = [ makeWrapper ];
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      # Electron registers t3code:// with this path. Prefer the profile link
      # so it still works after upgrades and garbage collection.
      makeWrapper ${desktopUnwrapped}/bin/t3code-desktop "$out/bin/t3code-desktop" \
        --run "export T3CODE_DESKTOP_LAUNCHER_PATH=\"\$(command -v t3code-desktop || echo $out/bin/t3code-desktop)\"" \
        ${pathArgs}
      install -Dm644 ${desktopExtracted}/t3code.desktop "$out/share/applications/t3code.desktop"
      substituteInPlace "$out/share/applications/t3code.desktop" \
        --replace-fail "Exec=AppRun %U" "Exec=$out/bin/t3code-desktop %U"
      mkdir -p "$out/share/icons"
      cp -r ${desktopExtracted}/usr/share/icons/hicolor "$out/share/icons/"
      runHook postInstall
    '';
    meta = meta // {
      description = "T3 Code nightly desktop";
      mainProgram = "t3code-desktop";
    };
  };

  cliUnwrapped = stdenvNoCC.mkDerivation {
    pname = "t3code-cli-nightly";
    inherit version;
    src = fetch cli;
    nativeBuildInputs = [
      makeWrapper
      pkgs.autoPatchelfHook
    ];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.vulkan-loader
    ];
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    # Preserve the SEA payload and the adjacent client, modules and libraries.
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/libexec/t3code-cli"
      tar -xzf "$src" -C "$out/libexec/t3code-cli" --strip-components=1
      # These bundled musl binaries are unused on glibc and break autoPatchelf.
      rm -rf \
        "$out/libexec/t3code-cli/node_modules/@yuuang/ffi-rs-linux-x64-musl" \
        "$out/libexec/t3code-cli/node_modules/@ff-labs/fff-bin-linux-x64-musl" \
        "$out/libexec/t3code-cli/node_modules/@koromix/koffi-linux-x64/musl_x64"
      test -x "$out/libexec/t3code-cli/t3"
      makeWrapper "$out/libexec/t3code-cli/t3" "$out/bin/t3" ${pathArgs}
      runHook postInstall
    '';
    meta = meta // {
      description = "T3 Code nightly CLI";
      mainProgram = "t3";
    };
  };
in
assert lib.assertMsg (
  pkgs.stdenv.hostPlatform.system == "x86_64-linux"
) "mkT3CodeNightly requires x86_64-linux";
pkgs.symlinkJoin {
  pname = "t3code-nightly";
  inherit version;
  paths = [
    desktopPackage
    cliUnwrapped
  ];
  passthru = {
    inherit desktopPackage cliUnwrapped;
    supportsProjectImport = manifest.supportsProjectImport or false;
  };
  meta = desktopPackage.meta // {
    description = "T3 Code nightly desktop and CLI";
  };
}
