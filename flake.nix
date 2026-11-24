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
          pkgs = nixpkgs.legacyPackages.${system};
          # Stub providers print the gateway URL so the check skips unfree builds.
          stub = name: pkgs.writeShellScriptBin name ''echo "''${AGY_LLM_GATEWAY_URL-}"'';
          configured = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [self.nixosModules.default {
              boot.isContainer = true;
              system.stateVersion = "26.05";
              programs.t3code = {
                enable = true;
                settings.theme = "dark";
                instructions = "Shared";
                skills = {
                  shared = "Shared skill";
                  override = "Shared override";
                };
                providers = {
                  codex = {
                    enable = true;
                    package = stub "codex";
                    settings.model = "gpt";
                    instructions = "Codex";
                    skills.override = "Codex override";
                  };
                  claudeCode = {
                    enable = true;
                    package = stub "claude";
                    settings.effortLevel = "high";
                    instructions = "Claude";
                  };
                  antigravity = {
                    enable = true;
                    package = stub "agy";
                    instructions = "Antigravity";
                    gateway = {
                      url = "https://gateway.test";
                      apiKeyFile = pkgs.writeText "gateway-key" "key";
                      models = ["model"];
                    };
                  };
                };
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
          inherit (configured.config.environment) etc;
          inherit (configured.config.programs.t3code) providers;
          # Evaluate units without building the packages they reference.
          units = pkgs.writeText "t3code-units" (builtins.unsafeDiscardStringContext (builtins.concatStringsSep "\n" [
            configured.config.systemd.user.units."t3code.service".text
            configured.config.systemd.user.units."t3code-settings.service".text
          ]));
        in
          pkgs.runCommand "t3code-module" {nativeBuildInputs = [pkgs.jq];} ''
            export HOME=$TMPDIR/home
            expect() { [ "$(cat "$1")" = "$2" ] || { echo "$1: unexpected $(cat "$1")"; exit 1; }; }

            grep -qx 'model = "gpt"' ${etc."codex/config.toml".source}
            expect ${etc."codex/skills/shared".source}/SKILL.md "Shared skill"
            expect ${etc."codex/skills/override".source}/SKILL.md "Codex override"
            ${providers.codex.finalPackage}/bin/codex
            expect $HOME/.codex/AGENTS.md "$(printf 'Shared\nCodex')"

            [ "$(jq -r .effortLevel ${etc."claude-code/managed-settings.json".source})" = high ]
            expect ${etc."claude-code/CLAUDE.md".source} "$(printf 'Shared\nClaude')"
            expect ${etc."claude-code/.claude/skills/override/SKILL.md".source} "Shared override"

            [ "$(${providers.antigravity.finalPackage}/bin/agy)" = https://gateway.test ]
            expect $HOME/.gemini/config/AGENTS.md "$(printf 'Shared\nAntigravity')"
            skills=$(jq -r '.entries[0].path' $HOME/.gemini/config/skills.json)
            expect $skills/shared/SKILL.md "Shared skill"
            expect $skills/override/SKILL.md "Shared override"

            acp_dir=$TMPDIR/acp-gemini
            [ -z "$(${providers.antigravity.finalPackage}/bin/agy acp --gemini-dir "$acp_dir")" ]
            expect "$acp_dir/config/AGENTS.md" "$(printf 'Shared\nAntigravity')"
            [ "$(jq -r '.entries[0].path' "$acp_dir/config/skills.json")" = "$skills" ]

            cp ${units} $out
          '';
      });
    nixosModules.default = import ./module.nix self;
  };
}
