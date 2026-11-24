# t3code-flake

[T3 Code](https://t3.codes) built from source for x86_64 Linux, aarch64 Linux, and macOS, with a NixOS module. 

## Installation

Add the flake as an input:

```nix
t3code.url = "github:greyxp1/t3code-flake";
```

Import the NixOS module. Add the binary cache to use pre-built packages.

```nix
{inputs, pkgs, ...}: {
  imports = [inputs.t3code.nixosModules.default];

  nix.settings = {
    extra-substituters = ["https://greyxp1.cachix.org"];
    extra-trusted-public-keys = ["greyxp1.cachix.org-1:hUnQC8sjfKykPgkFdcXiuv4xjiISuWnBnPfW2F2df3k="];
  };

  programs.t3code = {
    enable = true;
    package = inputs.t3code.packages.${pkgs.stdenv.hostPlatform.system}.nightly; # stable or nightly
    settings.providerInstances.codex = {
      driver = "codex";
      config.setupMode = "existing";
    };

    # Shared by all enabled providers. Provider instructions are appended and provider skills override shared ones.
    instructions = ''
      Prefer small, focused changes.
    '';
    skills.review = ''
      ---
      name: review
      description: Use when reviewing a change.
      ---
    '';

    # Installs and configures the CLIs, while settings.providerInstances configures how T3 Code invokes them.
    providers = {
      codex = {
        enable = true;
        # package = pkgs.codex;
        settings.model_reasoning_effort = "high"; # /etc/codex/config.toml
        # instructions = "";
        # skills = {};
      };
      claudeCode = {
        # enable = true;
        # package = pkgs.claude-code; # unfree
        # settings = {}; # /etc/claude-code/managed-settings.json
      };
      antigravity = {
        # enable = true;
        # package = pkgs.antigravity-cli; # unfree
        # Exported as GEMINI_API_KEY for ACP sessions.
        # apiKeyFile = "/run/secrets/gemini-api-key";
        # Gemini-compatible gateway for terminal agy sessions.
        # gateway = {
        #   url = "https://gateway.example";
        #   apiKeyFile = "/run/secrets/gateway-key";
        #   models = ["gemini-3-pro"];
        # };
      };
    };

    desktop = {
      # enable = true;
      # package = inputs.t3code.packages.${pkgs.stdenv.hostPlatform.system}.nightly.desktop;
      # settings = {};
    };

    # Headless server as a systemd user service.
    server = {
      enable = true;
      # Use graphical-session.target when agents need the desktop.
      # target = "default.target";
      # host = "127.0.0.1";
      # port = 3773;

      # Serve over HTTPS on your tailnet.
      # tailscaleServe = {
      #   enable = true;
      #   port = 443;
      # };

      # Reach this machine from app.t3.codes. Link it once with `t3 connect link`,
      # then `systemctl --user restart t3code`, as the server reads the link at startup.
      connect = {
        enable = true;
        # relayClient = pkgs.cloudflared;
        # Use "http2" on networks that block QUIC.
        # protocol = "http2";
      };
    };
  };
}
```
