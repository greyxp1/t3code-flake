{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.t3code;
  claudeCode = cfg.providers.claudeCode;
  format = pkgs.formats.json {};
  instructions = lib.concatStringsSep "\n" (lib.filter (s: s != "") [cfg.instructions claudeCode.instructions]);
in {
  options.programs.t3code.providers.claudeCode = {
    enable = lib.mkEnableOption "Claude Code";
    package = lib.mkPackageOption pkgs "claude-code" {};
    settings = lib.mkOption {
      type = format.type;
      default = {};
      description = "Managed settings that apply to every user and override their own settings.";
    };
    instructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Claude Code-specific instructions appended to the shared instructions in the managed CLAUDE.md.";
    };
    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Claude Code-specific managed skills merged over the shared skills, keyed by name.";
    };
  };

  config = lib.mkIf (cfg.enable && claudeCode.enable) {
    environment.systemPackages = [claudeCode.package];
    environment.etc =
      lib.optionalAttrs (claudeCode.settings != {}) {
        "claude-code/managed-settings.json".source = format.generate "managed-settings.json" claudeCode.settings;
      }
      // lib.optionalAttrs (instructions != "") {
        "claude-code/CLAUDE.md".text = instructions;
      }
      // lib.mapAttrs' (name: content:
        lib.nameValuePair "claude-code/.claude/skills/${name}/SKILL.md" {text = content;})
      (cfg.skills // claudeCode.skills);
  };
}
