{
  description = "Home Manager module for fine-grained T3 Code configuration";

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

      checks = forAllSystems (
        pkgs:
        import ./tests {
          inherit pkgs home-manager;
          module = self.homeManagerModules.t3code;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
