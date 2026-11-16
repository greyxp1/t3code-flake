{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpm_12,
  pnpmConfigHook,
  pnpmBuildHook,
  nodejs_26,
  nodejs-slim_26,
  node-gyp,
  pkg-config,
  autoPatchelfHook,
  libsecret,
  python3,
  cacert,
  electron_44,
  makeBinaryWrapper,
  installShellFiles,
  makeDesktopItem,
  rustPlatform,
  versionCheckHook,
  cctools,
  libicns,
  writeDarwinBundle,
  xcbuild,
  source,
}:

let
  pname = "t3code";
  inherit (source) version;
  pnpm = pnpm_12;

  src = fetchFromGitHub {
    owner = "pingdotgg";
    repo = "t3code";
    tag = "v${version}";
    inherit (source) hash;
  };

  # The web build's third-party-licenses vite plugin downloads SPDX license
  # texts unless they are already cached under .generated/. The updater keeps
  # rev in sync with SPDX_LICENSE_LIST_REVISION in scripts/lib/third-party-licenses.ts.
  spdxLicenses = fetchFromGitHub {
    owner = "spdx";
    repo = "license-list-data";
    rev = source.spdxRev;
    sparseCheckout = [ "json/details" ];
    hash = source.spdxHash;
  };

  resourceMonitor = rustPlatform.buildRustPackage {
    pname = "t3code-resource-monitor";
    inherit version src;

    sourceRoot = "${src.name}/native/resource-monitor";
    # inspects the test process's own RSS via procfs, 0 on some builders
    checkFlags = [ "--skip=tests::loads_details_when_an_existing_process_becomes_selected" ];
    inherit (source) cargoHash;
  };

  platformKey =
    {
      x86_64-linux = "linux-x64";
      aarch64-linux = "linux-arm64";
      aarch64-darwin = "darwin-arm64";
    }
    .${stdenv.hostPlatform.system};

  pnpmWorkspaces = [
    "@t3tools/monorepo"
    "t3..."
    "@t3tools/desktop..."
    "@t3tools/scripts..."
  ];

  appName = "T3 Code (Beta)";
  desktopIcon =
    if stdenv.hostPlatform.isDarwin then
      "assets/prod/black-macos-1024.png"
    else
      "assets/prod/black-universal-1024.png";

  desktopItem = makeDesktopItem {
    name = "t3code";
    desktopName = appName;
    comment = "Control surface for coding agents";
    exec = "t3code-desktop %U";
    icon = "t3code";
    categories = [ "Development" ];
    # On Wayland the app_id comes from app.setDesktopName(), which upstream
    # hardcodes to com.t3tools.T3Code.desktop. X11 uses `--class t3code`, which
    # shells still match to this entry by its t3code.desktop file name.
    startupWMClass = "com.t3tools.T3Code";
  };
in
stdenv.mkDerivation {
  inherit
    pname
    version
    src
    pnpmWorkspaces
    ;

  outputs = [
    "out"
    "desktop"
  ];

  strictDeps = true;
  __structuredAttrs = true;

  # Public production identifiers, also embedded in upstream release builds.
  # loadRepoEnv supplies the corresponding VITE_* values for the web frontend.
  env = {
    T3CODE_RELAY_URL = "https://relay.t3.codes";
    T3CODE_CLERK_PUBLISHABLE_KEY = "pk_live_Y2xlcmsudDMuY29kZXMk";
    T3CODE_CLERK_CLI_OAUTH_CLIENT_ID = "hzxSgY2cH10sDU2r";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit
      pnpm
      pname
      version
      src
      pnpmWorkspaces
      ;
    fetcherVersion = 5;
    hash = source.pnpmDepsHash;
  };

  nativeBuildInputs = [
    cacert
    installShellFiles
    makeBinaryWrapper
    node-gyp
    nodejs_26
    pnpm
    pnpmBuildHook
    pnpmConfigHook
    python3
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    autoPatchelfHook
    pkg-config
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    cctools.libtool
    libicns
    writeDarwinBundle
    xcbuild
  ];

  # build:desktop compiles native/browser-secret against libsecret on linux
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    libsecret
    stdenv.cc.cc.lib
  ];

  # We run electron on an unpacked tree, so app.isPackaged is false and the
  # backend would treat the store path as the workspace root (#9182).
  postPatch = ''
    substituteInPlace apps/desktop/src/app/DesktopEnvironment.ts \
      --replace-fail "backendCwd: input.isPackaged ? homeDirectory : appRoot," "backendCwd: homeDirectory,"

    spdxRev=$(sed -n 's/^const SPDX_LICENSE_LIST_REVISION = "\(.*\)";/\1/p' scripts/lib/third-party-licenses.ts)
    if [[ "$spdxRev" != "${spdxLicenses.rev}" ]]; then
      echo "error: upstream pins SPDX license-list-data $spdxRev, update spdxLicenses" >&2
      exit 1
    fi
    spdxVer=$(sed -n 's/^const SPDX_LICENSE_LIST_VERSION = "\(.*\)";/\1/p' scripts/lib/third-party-licenses.ts)
    mkdir -p .generated/third-party-licenses/spdx
    ln -s ${spdxLicenses}/json/details ".generated/third-party-licenses/spdx/$spdxVer"
  '';

  preBuild = ''
    export pnpm_config_verify_deps_before_run=false

    node scripts/update-release-package-versions.ts ${version}

    upstream_electron=$(node -p "require('./apps/desktop/package.json').dependencies.electron")
    upstream_major=''${upstream_electron#^}
    upstream_major=''${upstream_major%%.*}
    nix_major=${lib.versions.major electron_44.version}
    if (( upstream_major > nix_major )); then
      echo "error: upstream expects Electron $upstream_electron but nixpkgs provides ${electron_44.version}" >&2
      exit 1
    fi

    export npm_config_nodedir=${nodejs_26}
    export ELECTRON_SKIP_BINARY_DOWNLOAD=1
    pnpm rebuild --pending "''${pnpmInstallFlags[@]}" \
      --filter '!@t3tools/monorepo'
  '';

  pnpmBuildScript = "build:desktop";

  # Dependencies include prebuilt artifacts for foreign systems and statically
  # linked executables, which must not be patched or audited as host binaries.
  dontPatchELF = true;
  dontAutoPatchelf = true;
  noAuditTmpdir = true;

  installPhase = ''
    runHook preInstall

    # Match upstream's release packager without a second dependency install.
    # Preserve pnpm's layout for computed imports and native loaders.
    node --input-type=module <<'JS'
    import fs from 'node:fs';
    import path from 'node:path';
    import { selectCliRuntimeExternalDependencies } from './scripts/lib/cli-external-packages.ts';
    import { selectDesktopRuntimeExternalDependencies } from './scripts/lib/desktop-external-packages.ts';

    const store = fs.realpathSync('node_modules/.pnpm');
    const server = path.join(process.env.out, 'libexec/t3code/apps/server');
    const desktop = path.join(process.env.desktop, 'libexec/t3code/apps/desktop');
    const readManifest = directory => JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
    for (const [workspace, destination, select] of [
      ['apps/server', server, selectCliRuntimeExternalDependencies],
      ['apps/desktop', desktop, selectDesktopRuntimeExternalDependencies],
    ]) {
      const modules = path.join(destination, 'node_modules');
      fs.mkdirSync(path.join(modules, '.pnpm'), { recursive: true });
      const visited = new Set();
      function visit(directory, name, optional = false) {
        const link = path.join(directory, name);
        if (optional && !fs.existsSync(link)) return;
        const real = fs.realpathSync(link);
        const relative = path.relative(store, real);
        if (relative.startsWith('..') || path.isAbsolute(relative)) {
          throw new Error(`Runtime dependency outside pnpm store: ''${link}`);
        }
        const entry = relative.split(path.sep)[0];
        if (!visited.has(entry)) {
          visited.add(entry);
          const target = path.join(modules, '.pnpm', entry);
          const shared = path.join(server, 'node_modules/.pnpm', entry);
          if (destination !== server && fs.existsSync(shared)) {
            fs.symlinkSync(shared, target);
          } else {
            fs.cpSync(path.join(store, entry), target, { recursive: true, verbatimSymlinks: true });
            const manifest = readManifest(real);
            const siblings = path.resolve(real, ...name.split('/').map(() => '..'));
            for (const dependency of Object.keys(manifest.dependencies ?? {})) visit(siblings, dependency);
            for (const dependency of Object.keys(manifest.optionalDependencies ?? {})) visit(siblings, dependency, true);
            for (const dependency of Object.keys(manifest.peerDependencies ?? {})) {
              // Electron supplies its own module. TypeScript is only a type peer.
              if (dependency === 'electron' || dependency === 'typescript') continue;
              visit(siblings, dependency, manifest.peerDependenciesMeta?.[dependency]?.optional);
            }
          }
        }
        return path.join(modules, '.pnpm', relative);
      }
      const manifest = readManifest(workspace);
      for (const name of Object.keys(select(manifest.dependencies))) {
        const target = visit(path.join(workspace, 'node_modules'), name);
        const link = path.join(modules, name);
        fs.mkdirSync(path.dirname(link), { recursive: true });
        fs.symlinkSync(path.relative(path.dirname(link), target), link);
      }
      fs.copyFileSync(path.join(workspace, 'package.json'), path.join(destination, 'package.json'));
    }
    JS

    cp -r apps/server/dist "$out/libexec/t3code/apps/server/"

    mkdir -p "$out/libexec/t3code/apps/server/dist/resource-monitor/${platformKey}"
    install -Dm755 ${resourceMonitor}/bin/t3-resource-monitor \
      "$out/libexec/t3code/apps/server/dist/resource-monitor/${platformKey}/t3-resource-monitor"

    mkdir -p "$out/bin"
    makeWrapper ${lib.getExe nodejs-slim_26} "$out/bin/t3" \
      --add-flags "$out/libexec/t3code/apps/server/dist/bin.mjs"

    cp -r --no-preserve=mode apps/desktop/dist-electron "$desktop/libexec/t3code/apps/desktop/"
    cp -r apps/desktop/resources apps/desktop/gnome-extension "$desktop/libexec/t3code/apps/desktop/"
    mkdir -p "$desktop/libexec/t3code/apps/desktop/prod-resources"
    install -Dm444 ${desktopIcon} \
      "$desktop/libexec/t3code/apps/desktop/prod-resources/icon.png"

    ln -s "$out/libexec/t3code/apps/server" "$desktop/libexec/t3code/apps/server"

    mkdir -p "$desktop/libexec/t3code/apps/desktop/prod-resources/resource-monitor"
    ln -s \
      "$out/libexec/t3code/apps/server/dist/resource-monitor/${platformKey}/t3-resource-monitor" \
      "$desktop/libexec/t3code/apps/desktop/prod-resources/resource-monitor/t3-resource-monitor"

    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      install -Dm755 native/browser-secret/build/${stdenv.hostPlatform.node.arch}/t3-browser-secret \
        "$desktop/libexec/t3code/apps/desktop/prod-resources/browser-secret/t3-browser-secret"
    ''}

    # Debug maps and declarations are not loaded by the emitted JS bundles.
    find "$out/libexec/t3code" "$desktop/libexec/t3code" -type f \
      \( -name '*.map' -o -name '*.d.ts' -o -name '*.d.cts' -o -name '*.d.mts' \) -delete
    find "$out/libexec/t3code" "$desktop/libexec/t3code" -xtype l -delete
    # The runtime imports packages directly, so pnpm's command shims are unused. Dependency
    # scripts get the slim Node, as the full one would add npm to the closure.
    find "$out/libexec/t3code" "$desktop/libexec/t3code" -type d -path '*/node_modules/.bin' -prune -exec rm -r {} +
    grep -rlZ ${nodejs_26}/bin/node "$out/libexec/t3code" "$desktop/libexec/t3code" \
      | xargs -0r sed -i '1s|${nodejs_26}/bin/node|${lib.getExe nodejs-slim_26}|'

    # Native modules ship prebuilds for every platform, and node-pty also
    # bundles Windows-only ConPTY binaries.
    find "$out/libexec/t3code" "$desktop/libexec/t3code" \
      \( -path '*/prebuilds/*' ! -path '*/prebuilds/*/*' ! -name ${platformKey} \
        -o -path '*/node-pty/third_party' \) \
      -prune -exec rm -r {} +

    mkdir -p "$desktop/bin"
    # Without the launcher path the desktop app falls back to bare electron
    # for `Exec=` in the t3code:// URL handler entry it writes on Linux.
    makeWrapper ${lib.getExe electron_44} "$desktop/bin/t3code-desktop" \
      --add-flags "$desktop/libexec/t3code/apps/desktop" \
      ${lib.optionalString stdenv.hostPlatform.isLinux ''--set-default T3CODE_DESKTOP_LAUNCHER_PATH "$desktop/bin/t3code-desktop"''} \
      --inherit-argv0

    mkdir -p "$desktop/share/icons/hicolor/scalable/apps"
    install -Dm444 ${desktopIcon} "$desktop/share/icons/t3code.png"
    install -Dm444 assets/prod/logo.svg "$desktop/share/icons/hicolor/scalable/apps/t3code.svg"
    cp -r ${desktopItem}/share/applications "$desktop/share/"

    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      find "$out/libexec/t3code" "$desktop/libexec/t3code" \
        -path '*/node-pty/prebuilds/darwin-*/spawn-helper' \
        -exec chmod 755 {} +

      mkdir -p "$desktop/Applications/${appName}.app/Contents/"{MacOS,Resources}
      png2icns \
        "$desktop/Applications/${appName}.app/Contents/Resources/t3code.icns" \
        ${desktopIcon}
      ${stdenv.shell} ${lib.getExe writeDarwinBundle} \
        "$desktop" "${appName}" t3code-desktop t3code
    ''}

    runHook postInstall
  '';

  # Electron, unlike node, does not already have libstdc++ loaded for the
  # prebuilt pty.node (#10125).
  postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    autoPatchelf "$out/libexec/t3code/apps/server/node_modules/node-pty/prebuilds/${platformKey}"
  '';

  postInstall = ''
    for shell in bash fish zsh; do
      installShellCompletion --cmd t3 --"$shell" <("$out/bin/t3" --completions "$shell")
    done
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  # t3 needs a writable home even for --version.
  preInstallCheck = ''
    export HOME=$(mktemp -d)
  '';
  versionCheckKeepEnvironment = "HOME";
  versionCheckProgramArg = [ "--version" ];

  passthru = {
    inherit appName resourceMonitor spdxLicenses;
  };

  meta = {
    description = "Control surface for coding agents";
    homepage = "https://t3.codes";
    changelog = "https://github.com/pingdotgg/t3code/releases/tag/v${version}";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
    mainProgram = "t3";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
