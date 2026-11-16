{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    forAllSystems = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
  in {
    packages = forAllSystems (system: let
      t3code = channel: nixpkgs.legacyPackages.${system}.callPackage ./package.nix {source = import ./sources/${channel}.nix;};
    in rec {
      stable = t3code "stable";
      nightly = t3code "nightly";
      default = stable;
    });
    checks = forAllSystems (system:
      nixpkgs.lib.optionalAttrs (nixpkgs.lib.hasSuffix "-linux" system) {
        module = let
          configured = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [self.nixosModules.default {
              boot.isContainer = true;
              system.stateVersion = "26.05";
              programs.t3code = {
                enable = true;
                settings.theme = "dark";
                desktop = {
                  enable = true;
                  settings.theme = "dark";
                };
                server = {
                  enable = true;
                  connect = {
                    enable = true;
                    protocol = "http2";
                  };
                  tailscaleServe.enable = true;
                };
              };
            }];
          };
        # Evaluate units without building the packages they reference.
        in nixpkgs.legacyPackages.${system}.writeText "t3code-units" (builtins.unsafeDiscardStringContext (builtins.concatStringsSep "\n" [
          configured.config.systemd.user.units."t3code.service".text
          configured.config.systemd.user.units."t3code-settings.service".text
        ]));
      });
    nixosModules.default = import ./module.nix self;
  };
}
