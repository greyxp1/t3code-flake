{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = {
    self,
    nixpkgs,
    ...
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
          # Stub providers print the gateway URL and Gemini API key so the check skips unfree builds.
          stub = name: pkgs.writeShellScriptBin name ''echo "''${AGY_LLM_GATEWAY_URL-}|''${GEMINI_API_KEY-}"'';
          configure = override: nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [self.nixosModules.default override {
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
                    apiKeyFile = pkgs.writeText "acp-key" "acp-secret";
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
          configured = configure {};
          # Drops managed customizations and points the gateway and ACP key at missing files.
          cleared = (configure {
            programs.t3code = {
              instructions = nixpkgs.lib.mkForce "";
              skills = nixpkgs.lib.mkForce {};
              providers.codex.instructions = nixpkgs.lib.mkForce "";
              providers.antigravity.instructions = nixpkgs.lib.mkForce "";
              providers.antigravity.apiKeyFile = nixpkgs.lib.mkForce "/nonexistent/acp-key";
              providers.antigravity.gateway.apiKeyFile = nixpkgs.lib.mkForce "/nonexistent/gateway-key";
            };
          }).config.programs.t3code.providers;
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

            agy_out=$(${providers.antigravity.finalPackage}/bin/agy)
            [ "$agy_out" = "https://gateway.test|" ]
            expect $HOME/.gemini/config/AGENTS.md "$(printf 'Shared\nAntigravity')"
            skills=$(jq -r '.entries[0].path' $HOME/.gemini/config/skills.json)
            expect $skills/shared/SKILL.md "Shared skill"
            expect $skills/override/SKILL.md "Shared override"

            acp_dir=$TMPDIR/acp-gemini
            acp_out=$(GEMINI_API_KEY=stale ${providers.antigravity.finalPackage}/bin/agy acp --gemini-dir "$acp_dir")
            [ "$acp_out" = "|acp-secret" ]
            expect "$acp_dir/config/AGENTS.md" "$(printf 'Shared\nAntigravity')"
            [ "$(jq -r '.entries[0].path' "$acp_dir/config/skills.json")" = "$skills" ]

            # Cleared customizations remove managed links but keep user files.
            ${cleared.codex.finalPackage}/bin/codex
            agy_out=$(${cleared.antigravity.finalPackage}/bin/agy 2>$TMPDIR/agy-stderr)
            [ "$agy_out" = "|" ]
            grep -q 'agy: warning: failed to read gateway apiKeyFile' $TMPDIR/agy-stderr
            acp_out=$(${cleared.antigravity.finalPackage}/bin/agy acp 2>$TMPDIR/agy-acp-stderr)
            [ "$acp_out" = "|" ]
            grep -q 'agy: warning: failed to read apiKeyFile' $TMPDIR/agy-acp-stderr
            for managed in .codex/AGENTS.md .gemini/config/AGENTS.md .gemini/config/skills.json; do
              [ ! -L "$HOME/$managed" ] || { echo "$managed: not removed"; exit 1; }
            done
            mkdir -p $HOME/.codex $HOME/.gemini/config
            echo mine > $HOME/.codex/AGENTS.md
            echo mine > $TMPDIR/mine
            ln -s $TMPDIR/mine $HOME/.gemini/config/AGENTS.md
            ln -s $TMPDIR/mine $HOME/.gemini/config/skills.json
            ${cleared.codex.finalPackage}/bin/codex
            ${cleared.antigravity.finalPackage}/bin/agy 2>/dev/null
            expect $HOME/.codex/AGENTS.md mine
            expect $HOME/.gemini/config/AGENTS.md mine
            expect $HOME/.gemini/config/skills.json mine

            cp ${units} $out
          '';
      });
    nixosModules.default = import ./module.nix self;
  };
}
