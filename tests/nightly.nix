{ pkgs, mkT3CodeNightly }:
let
  inherit (pkgs) lib;
  tool = pkgs.writeShellScriptBin "provider" "exit 0";
  package = mkT3CodeNightly {
    inherit pkgs;
    runtimePackages = [ tool ];
    # Evaluation-only: don't download or publish these placeholder assets.
    manifest = {
      version = "0.0.1-nightly";
      supportsProjectImport = true;
      assets = {
        cli = {
          url = "https://example.org/t3-linux-x64.tar.gz";
          sha256 = builtins.hashString "sha256" "fixture CLI";
        };
        desktop = {
          url = "https://example.org/T3-Code-x86_64.AppImage";
          hash = lib.fakeHash;
        };
      };
    };
  };
  inherit (package) cliUnwrapped desktopPackage;
  hasTool =
    phase:
    builtins.hasAttr (builtins.unsafeDiscardStringContext tool.drvPath) (builtins.getContext phase);
in
assert lib.isDerivation package && package.version == "0.0.1-nightly";
assert package.supportsProjectImport;
assert package.meta.mainProgram == "t3code-desktop" && cliUnwrapped.meta.mainProgram == "t3";
assert cliUnwrapped.dontStrip;
assert hasTool cliUnwrapped.installPhase;
assert hasTool desktopPackage.installPhase;
assert lib.hasSuffix ".drv" (builtins.unsafeDiscardStringContext package.drvPath);
pkgs.runCommand "t3code-nightly-eval" { } "touch $out"
