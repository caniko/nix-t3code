# Google's Antigravity CLI, which serves ACP itself (`antigravity acp`) since
# 1.5.0 and replaced the standalone agy-acp-server zip T3 Code used to run.
# Version and URLs follow the CLI auto-updater's stable manifests:
# https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_{amd64,arm64}.json
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  versionCheckHook,
}:
let
  version = "1.5.13";
  buildId = "5999302598852608";
  releases = {
    x86_64-linux = {
      path = "linux-x64/cli_linux_x64";
      hash = "sha256-f6nMbfDQlWJpPWN8QGqGwbD1KrM2RxSx/S15zGBg1LI=";
    };
    aarch64-linux = {
      path = "linux-arm/cli_linux_arm64";
      hash = "sha256-Nllq2AOFMf118Ol7W6iWejDy/Wf42cYZWdLkdh17IV8=";
    };
  };
  release =
    releases.${stdenvNoCC.hostPlatform.system}
      or (throw "agy-acp-server: unsupported system ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "agy-acp-server";
  inherit version;

  src = fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-${buildId}/${release.path}.tar.gz";
    inherit (release) hash;
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  sourceRoot = ".";

  # T3 recognises the CLI by its file name (agy or antigravity) and then runs
  # `<binary> acp` with no localharness_external sibling.
  installPhase = ''
    runHook preInstall
    install -Dm755 antigravity $out/bin/antigravity
    runHook postInstall
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  meta = {
    description = "Google Antigravity CLI, run by T3 Code as its Agent Client Protocol server";
    homepage = "https://antigravity.google";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames releases;
    mainProgram = "antigravity";
  };
}
