{
  description = "Home Manager and NixOS modules for T3 Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      homeManagerModules = {
        default = self.homeManagerModules.t3code;
        t3code = ./modules/t3code.nix;
      };

      nixosModules.t3codeServer = ./modules/server.nix;
      nixosModules.t3codeBackup = ./modules/backup.nix;

      lib.mkT3CodeNightly = import ./pkgs/mk-t3code-nightly.nix;

      checks = forAllSystems (
        pkgs:
        import ./tests {
          inherit pkgs home-manager;
          module = self.homeManagerModules.t3code;
          serverModule = self.nixosModules.t3codeServer;
        }
        // {
          backup = import ./tests/backup.nix {
            inherit pkgs;
            module = self.nixosModules.t3codeBackup;
          };
        }
        // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          nightly = import ./tests/nightly.nix {
            inherit pkgs;
            inherit (self.lib) mkT3CodeNightly;
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
