{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.t3code;
  antigravity = cfg.providers.antigravity;
  format = pkgs.formats.json {};
  gateway = antigravity.gateway;
  instructions = lib.concatStringsSep "\n" (lib.filter (s: s != "") [cfg.instructions antigravity.instructions]);
  skills = cfg.skills // antigravity.skills;
  hasInstructions = instructions != "";
  hasSkills = skills != {};
  needsWrapper = gateway != null || hasInstructions || hasSkills;
  instructionsFile = pkgs.writeText "antigravity-AGENTS.md" instructions;
  skillsDir = pkgs.linkFarm "antigravity-skills" (
    lib.mapAttrsToList (name: content: {
      name = "${name}/SKILL.md";
      path = pkgs.writeText "${name}-SKILL.md" content;
    })
    skills
  );
  skillsFile = format.generate "antigravity-skills.json" {
    entries = [{path = toString skillsDir;}];
  };
  coreutils = pkgs.coreutils;
  parseArgsScript = lib.optionalString needsWrapper ''
    subcmd=""
    default_gemini_dir="''${HOME:+$HOME/.gemini}"
    gemini_dir="$default_gemini_dir"
    acp_help=0
    state=root
    for arg in "$@"; do
      case "$state" in
        root_val)
          state=root
          ;;
        root|root_end)
          case "$state:$arg" in
            root:--)
              state=root_end
              continue
              ;;
            root:-?*)
              name="''${arg#-}"
              name="''${name#-}"
              case "$name" in
                version)
                  break
                  ;;
                add-dir|agent|conversation|effort|i|prompt-interactive|input-format|json-schema|log-file|mode|model|output-format|p|print|print-timeout|project|prompt|settings)
                  state=root_val
                  ;;
                *)
                  case "''${name%%=*}" in
                    add-dir|agent|c|continue|conversation|dangerously-skip-permissions|disable-slash-commands|effort|i|input-format|json-schema|log-file|mode|model|new-project|output-format|p|print|print-timeout|project|prompt|prompt-interactive|remote-agent|remote-control|sandbox|settings|version)
                      ;;
                    *)
                      break
                      ;;
                  esac
                  ;;
              esac
              continue
              ;;
          esac
          subcmd="$arg"
          if [ "$subcmd" = "acp" ]; then
            state=acp
          else
            break
          fi
          ;;
        acp_val)
          state=acp
          ;;
        acp_gemini_dir)
          gemini_dir="''${arg:-$default_gemini_dir}"
          state=acp
          ;;
        acp)
          case "$arg" in
            --)
              break
              ;;
            -?*)
              name="''${arg#-}"
              name="''${name#-}"
              case "$name" in
                h|help|h=1|h=t|h=T|h=true|h=TRUE|h=True|help=1|help=t|help=T|help=true|help=TRUE|help=True)
                  acp_help=1
                  ;;
                h=0|h=f|h=F|h=false|h=FALSE|h=False|help=0|help=f|help=F|help=false|help=FALSE|help=False)
                  acp_help=0
                  ;;
                gemini-dir|gemini_dir)
                  state=acp_gemini_dir
                  ;;
                gemini-dir=*|gemini_dir=*)
                  val="''${name#*=}"
                  gemini_dir="''${val:-$default_gemini_dir}"
                  ;;
                add-dir|agent|app-data-dir|app_data_dir|cli_dir_name|cli_log_file|cloud_code_endpoint|ide-mcp-port|ide_mcp_port|log-file|override_user_agent_name)
                  state=acp_val
                  ;;
                *)
                  case "''${name%%=*}" in
                    add-dir|agent|app-data-dir|app_data_dir|cli_dir_name|cli_log_file|cloud_code_endpoint|dangerously-skip-permissions|disable-telemetry|disable_telemetry|ide-mcp-port|ide_mcp_port|include-default-customizations|is_google3_workspace|is_google_internal|log-file|login|override_user_agent_name|process-per-session|sandbox|stdio|use_stubby_auth|worker)
                      ;;
                    *)
                      gemini_dir="$default_gemini_dir"
                      break
                      ;;
                  esac
                  ;;
              esac
              ;;
            *)
              break
              ;;
          esac
          ;;
      esac
    done
    if [ "$acp_help" -eq 1 ] || [ "$state" = "acp_val" ] || [ "$state" = "acp_gemini_dir" ]; then
      gemini_dir="$default_gemini_dir"
    fi
  '';
  customizationsScript = lib.optionalString (hasInstructions || hasSkills) ''
    case "$gemini_dir" in
      ""|/*) ;;
      *)
        if [ -n "''${HOME-}" ]; then
          gemini_dir="$HOME/$gemini_dir"
        else
          gemini_dir=""
        fi
        ;;
    esac
    link_managed() {
      if [ "$("${lib.getExe' coreutils "readlink"}" -f "$2" 2>/dev/null)" != "$1" ]; then
        "${lib.getExe' coreutils "mkdir"}" -p "$config_dir"
        "${lib.getExe' coreutils "ln"}" -sfnT "$1" "$2"
      fi
    }
    sync_dir() {
      config_dir="$1/config"
      ${lib.optionalString hasInstructions ''
        link_managed ${lib.escapeShellArg (toString instructionsFile)} "$config_dir/AGENTS.md"
      ''}
      ${lib.optionalString hasSkills ''
        link_managed ${lib.escapeShellArg (toString skillsFile)} "$config_dir/skills.json"
      ''}
    }
    if [ -n "$default_gemini_dir" ] && [ "$gemini_dir" != "$default_gemini_dir" ]; then
      (sync_dir "$default_gemini_dir") 2>/dev/null || true
    fi
    if [ -n "$gemini_dir" ]; then
      (sync_dir "$gemini_dir") 2>/dev/null || true
    fi
  '';
  gatewayScript = lib.optionalString (gateway != null) ''
    if [ "$subcmd" != "acp" ] && gateway_api_key="$("${lib.getExe' coreutils "cat"}" ${lib.escapeShellArg gateway.apiKeyFile} 2>/dev/null)"; then
      export AGY_LLM_GATEWAY_URL=${lib.escapeShellArg gateway.url}
      export AGY_LLM_GATEWAY_WIRE_PROTOCOL=genai
      export AGY_LLM_GATEWAY_MODELS=${lib.escapeShellArg (lib.concatStringsSep "," gateway.models)}
      export AGY_LLM_GATEWAY_API_KEY="$gateway_api_key"
    fi
  '';
  wrappedPackage = pkgs.symlinkJoin {
    name = "antigravity-cli-configured";
    paths = [antigravity.package];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram "$out/bin/agy" \
        --run ${lib.escapeShellArg (parseArgsScript + customizationsScript + gatewayScript)}
    '';
    meta = antigravity.package.meta;
  };
in {
  options.programs.t3code.providers.antigravity = {
    enable = lib.mkEnableOption "Antigravity CLI";
    package = lib.mkPackageOption pkgs "antigravity-cli" {};
    instructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Antigravity-specific instructions appended to the shared instructions in each Antigravity config directory's AGENTS.md.";
    };
    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Antigravity-specific skills merged over the shared skills and registered in each Antigravity config directory's skills.json, keyed by name.";
    };
    gateway = lib.mkOption {
      default = null;
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Base URL of a Gemini-compatible model gateway.";
          };
          apiKeyFile = lib.mkOption {
            type = lib.types.path;
            description = "Path to the gateway API key, read at launch.";
          };
          models = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Model identifiers exposed by the gateway.";
          };
        };
      });
      description = "Gateway settings for terminal agy invocations. ACP sessions select authentication over the protocol instead.";
    };
    finalPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "Antigravity CLI with its managed configuration.";
    };
  };

  config = lib.mkIf (cfg.enable && antigravity.enable) {
    programs.t3code.providers.antigravity.finalPackage =
      if needsWrapper
      then wrappedPackage
      else antigravity.package;
    environment.systemPackages = [antigravity.finalPackage];
  };
}
