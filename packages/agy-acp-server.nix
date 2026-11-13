# Google's Antigravity ACP server, the runtime T3 Code otherwise downloads into
# its home. Release URLs and hashes match apps/server/src/provider/antigravityRelease.ts.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  autoPatchelfHook,
}:
let
  version = "1.4.5";
  releases = {
    x86_64-linux = {
      arch = "x86_64";
      hash = "sha256-kjkjoNfcgHP2bMb3hkejEH46fuK34aJN+LOSe1GIATs=";
    };
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-fWQkZjOuCU9n47vNLWeeiQSPkTRtUzkxMzbnSD9A8FY=";
    };
  };
  release =
    releases.${stdenv.hostPlatform.system}
      or (throw "agy-acp-server: unsupported system ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "agy-acp-server";
  inherit version;

  src = fetchurl {
    url = "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-${version}-linux-${release.arch}.zip";
    inherit (release) hash;
  };

  nativeBuildInputs = [
    unzip
    autoPatchelfHook
  ];
  sourceRoot = ".";

  # The .par is an ELF launcher with the Python app zipped onto its end: stripping
  # or shrinking it would cut the payload. Only the interpreter needs patching.
  dontStrip = true;
  dontPatchELF = true;

  # T3 runs bin/agy_acp_server.par and requires localharness_external next to it.
  installPhase = ''
    runHook preInstall
    install -Dm755 -t $out/bin agy_acp_server.par localharness_external
    runHook postInstall
  '';

  meta = {
    description = "Google Antigravity Agent Client Protocol server";
    homepage = "https://antigravity.google";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames releases;
    mainProgram = "agy_acp_server.par";
  };
}
