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

      checks = forAllSystems (
        pkgs:
        import ./tests {
          inherit pkgs home-manager;
          module = self.homeManagerModules.t3code;
          serverModule = self.nixosModules.t3codeServer;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
