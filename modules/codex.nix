{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.t3code;
  codex = cfg.providers.codex;
  format = pkgs.formats.toml {};
  instructions = lib.concatStringsSep "\n" (lib.filter (s: s != "") [cfg.instructions codex.instructions]);
  instructionsFile = pkgs.writeText "codex-AGENTS.md" instructions;
in {
  options.programs.t3code.providers.codex = {
    enable = lib.mkEnableOption "Codex";
    package = lib.mkPackageOption pkgs "codex" {};
    settings = lib.mkOption {
      type = format.type;
      default = {};
      description = "System-wide Codex settings.";
    };
    instructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Codex-specific instructions appended to the shared instructions in each Codex home's AGENTS.md.";
    };
    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Codex-specific system-wide skills merged over the shared skills, keyed by name.";
    };
    finalPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "Codex with its managed instructions.";
    };
  };

  config = lib.mkIf (cfg.enable && codex.enable) {
    programs.t3code.providers.codex.finalPackage =
      if instructions == ""
      then codex.package
      else
        pkgs.symlinkJoin {
          name = "codex-configured";
          paths = [codex.package];
          nativeBuildInputs = [pkgs.makeWrapper];
          postBuild = ''
            wrapProgram $out/bin/codex --run ${lib.escapeShellArg ''
              codex_home="''${CODEX_HOME:-$HOME/.codex}"
              if [ "$(${pkgs.coreutils}/bin/readlink "$codex_home/AGENTS.md" 2>/dev/null)" != ${lib.escapeShellArg (toString instructionsFile)} ]; then
                ${pkgs.coreutils}/bin/mkdir -p "$codex_home"
                ${pkgs.coreutils}/bin/ln -sfnT ${instructionsFile} "$codex_home/AGENTS.md"
              fi
            ''}
          '';
          meta = codex.package.meta;
        };
    environment.systemPackages = [codex.finalPackage];
    environment.etc =
      {
        "codex/config.toml".source = format.generate "codex-system-config.toml" codex.settings;
      }
      // lib.mapAttrs' (name: content:
        lib.nameValuePair "codex/skills/${name}" {
          source = pkgs.writeTextDir "SKILL.md" content;
        })
      (cfg.skills // codex.skills);
  };
}
