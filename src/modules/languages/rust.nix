{ pkgs, config, lib, ... }:

let
  cfg = config.languages.rust;

  rust-overlay = config.lib.getInput {
    name = "rust-overlay";
    url = "github:oxalica/rust-overlay";
    attribute = "languages.rust.input";
    follows = [ "nixpkgs" ];
  };

  cargo2nix = config.lib.getInput {
    name = "cargo2nix";
    url = "github:cargo2nix/cargo2nix";
    attribute = "languages.rust.cargo2nixInput";
    follows = [ "nixpkgs" ];
  };

  # https://github.com/nix-community/fenix/blob/cdfd7bf3e3edaf9e3f6d1e397d3ee601e513613c/lib/combine.nix
  combine = name: paths:
    pkgs.symlinkJoin {
      inherit name paths;
      postBuild = ''
        for file in $(find $out/bin -xtype f -maxdepth 1); do
          install -m755 $(realpath "$file") $out/bin
    
          if [[ $file =~ /rustfmt$ ]]; then
            continue
          fi
    
          ${lib.optionalString pkgs.stdenv.isLinux ''
            if isELF "$file"; then
              patchelf --set-rpath $out/lib "$file" || true
            fi
          ''}
    
          ${lib.optionalString pkgs.stdenv.isDarwin ''
            install_name_tool -add_rpath $out/lib "$file" || true
          ''}
        done
    
        for file in $(find $out/lib -name "librustc_driver-*"); do
          install $(realpath "$file") "$file"
        done
      '';
    };
in
{
  imports = [
    (lib.mkRenamedOptionModule [ "languages" "rust" "packages" ] [ "languages" "rust" "toolchain" ])
  ];

  options.languages.rust = {
    enable = lib.mkEnableOption "tools for Rust development";

    components = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "rustc" "cargo" "clippy" "rustfmt" "rust-analyzer" ];
      defaultText = lib.literalExpression ''[ "rustc" "cargo" "clippy" "rustfmt" "rust-analyzer" ]'';
      description = ''
        List of [Rustup components](https://rust-lang.github.io/rustup/concepts/components.html)
        to install. Defaults to those available in `nixpkgs`.
      '';
    };

    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      defaultText = lib.literalExpression ''[ ]'';
      description = ''
        List of extra [targets](https://doc.rust-lang.org/nightly/rustc/platform-support.html)
        to install. Defaults to only the native target. 
      '';
    };

    channel = lib.mkOption {
      type = lib.types.enum [ "nixpkgs" "stable" "beta" "nightly" ];
      default = "nixpkgs";
      defaultText = lib.literalExpression ''"nixpkgs"'';
      description = "The rustup toolchain to install.";
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "latest";
      defaultText = lib.literalExpression ''"latest"'';
      description = ''
        Which version of rust to use, this value could be `latest`,`1.81.0`, `2021-01-01`.
        Only works when languages.rust.channel is NOT nixpkgs.
      '';
    };

    rustflags = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Extra flags to pass to the Rust compiler.";
    };

    mold.enable = lib.mkOption {
      type = lib.types.bool;
      default = pkgs.stdenv.isLinux && pkgs.stdenv.isx86_64 && cfg.targets == [ ];
      defaultText =
        lib.literalExpression "pkgs.stdenv.isLinux && pkgs.stdenv.isx86_64 && languages.rust.targets == [ ]";
      description = ''
        Enable mold as the linker.

        Enabled by default on x86_64 Linux machines when no cross-compilation targets are specified.
      '';
    };

    toolchain = lib.mkOption {
      type = lib.types.submodule ({
        freeformType = lib.types.attrsOf lib.types.package;

        options =
          let
            documented-components = [ "rustc" "cargo" "clippy" "rustfmt" "rust-analyzer" ];
            mkComponentOption = component: lib.mkOption {
              type = lib.types.nullOr lib.types.package;
              default = pkgs.${component};
              defaultText = lib.literalExpression "pkgs.${component}";
              description = "${component} package";
            };
          in
          lib.genAttrs documented-components mkComponentOption;
      });
      default = { };
      defaultText = lib.literalExpression "nixpkgs";
      description = "Rust component packages. May optionally define additional components, for example `miri`.";
    };

    import = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
        options = {
          root = lib.mkOption {
            type = lib.types.path;
            description = "Path to the directory containing Cargo.toml";
          };

          workspaceMembers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "List of workspace members to build. If empty, builds all workspace members";
          };

          package = lib.mkOption {
            type = lib.types.package;
            readOnly = true;
            description = "The built package or workspace";
            default =
              let
                cargoNixPath = config.root + "/Cargo.nix";
                cargoTomlPath = config.root + "/Cargo.toml";

                # Check if Cargo.nix exists
                cargoNixExists = builtins.pathExists cargoNixPath;

                # Check if Cargo.toml exists
                cargoTomlExists = builtins.pathExists cargoTomlPath;

                # Use the same rust version as configured
                rustVersion = if cfg.channel != "nixpkgs" then cfg.version else "latest";
                rustChannel = cfg.channel;

                rustPkgs = pkgs.rustBuilder.makePackageSet {
                  rustVersion = if rustChannel == "nixpkgs" then "latest" else rustVersion;
                  rustChannel = if rustChannel == "nixpkgs" then "stable" else rustChannel;
                  packageFun = import cargoNixPath;
                };
              in
              assert lib.assertMsg cargoTomlExists
                "Cargo.toml not found at ${toString cargoTomlPath}. Please ensure the 'root' path points to a directory containing Cargo.toml.";
              if !cargoNixExists then
                throw "Cargo.nix not found at ${toString cargoNixPath}. Please run 'devenv tasks run cargo2nix:${name}' to generate it."
              else if config.workspaceMembers == [ ] then
              # Return the entire workspace when no specific members are specified
                rustPkgs.workspace
              else if builtins.length config.workspaceMembers == 1 then
              # Single workspace member
                rustPkgs.workspace.${builtins.head config.workspaceMembers} { }
              else
              # Multiple workspace members - create a combined derivation
                pkgs.symlinkJoin {
                  name = "${name}-combined";
                  paths = map (member: rustPkgs.workspace.${member} { }) config.workspaceMembers;
                  passthru = lib.listToAttrs (map
                    (member: {
                      name = member;
                      value = rustPkgs.workspace.${member} { };
                    })
                    config.workspaceMembers);
                };
          };
        };
      }));
      default = { };
      description = ''
        Import Rust projects using cargo2nix for granular builds.
        
        Example:
        ```nix
        languages.rust.import = {
          myProject = {
            root = ./.; # Directory containing Cargo.toml
          };
          
          anotherProject = {
            root = ./other;
            workspaceMember = "my-crate";
          };
        };
        
        # Then use the packages:
        packages = [ 
          config.languages.rust.import.myProject.package
        ];
        ```
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (
      let
        mkOverrideTools = lib.mkOverride (lib.modules.defaultOverridePriority - 1);
      in
      {
        assertions = [
          {
            assertion = cfg.channel == "nixpkgs" -> (cfg.targets == [ ]);
            message = ''
              Cannot use `languages.rust.channel = "nixpkgs"` with `languages.rust.targets`.

              The nixpkgs channel does not support cross-compiling with targets.
              Use the stable, beta, or nightly channels instead. For example:

              languages.rust.channel = "stable";
            '';
          }
          {
            assertion = cfg.channel == "nixpkgs" -> (cfg.version == "latest");
            message = ''
              Cannot use `languages.rust.channel = "nixpkgs"` with `languages.rust.version`.

              The nixpkgs channel does not contain all versions required, and is
              therefore not supported to be used together.

              languages.rust.channel = "stable";
            '';
          }
        ];

        # Set $CARGO_INSTALL_ROOT so that executables installed by `cargo install` can be found from $PATH
        enterShell = ''
          export CARGO_INSTALL_ROOT=$(${
            lib.strings.escapeShellArgs [
              "${pkgs.coreutils}/bin/realpath"
              "--no-symlinks"
              "${config.devenv.state}/cargo-install"
            ]
          })
          export PATH="$PATH:$CARGO_INSTALL_ROOT/bin"
        '';

        packages =
          lib.optional cfg.mold.enable pkgs.mold-wrapped
          ++ lib.optional pkgs.stdenv.isDarwin pkgs.libiconv;

        # enable compiler tooling by default to expose things like cc
        languages.c.enable = lib.mkDefault true;

        env =
          let
            moldFlags = lib.optionalString cfg.mold.enable "-C link-arg=-fuse-ld=mold";
            optionalEnv = cond: str: if cond then str else null;
          in
          {
            # RUST_SRC_PATH is necessary when rust-src is not at the same location as
            # as rustc. This is the case with the rust toolchain from nixpkgs.
            RUST_SRC_PATH =
              if cfg.toolchain ? rust-src
              then "${cfg.toolchain.rust-src}/lib/rustlib/src/rust/library"
              else pkgs.rustPlatform.rustLibSrc;
            RUSTFLAGS = optionalEnv (moldFlags != "" || cfg.rustflags != "") (lib.concatStringsSep " " (lib.filter (x: x != "") [ moldFlags cfg.rustflags ]));
            RUSTDOCFLAGS = optionalEnv (moldFlags != "") moldFlags;
            CFLAGS = lib.optionalString pkgs.stdenv.isDarwin "-iframework ${config.devenv.profile}/Library/Frameworks";
          };

        git-hooks.tools.cargo = mkOverrideTools cfg.toolchain.cargo or null;
        git-hooks.tools.rustfmt = mkOverrideTools cfg.toolchain.rustfmt or null;
        git-hooks.tools.clippy = mkOverrideTools cfg.toolchain.clippy or null;
      }
    )

    (lib.mkIf (cfg.channel == "nixpkgs") {
      packages = builtins.map (c: cfg.toolchain.${c} or (throw "toolchain.${c}")) cfg.components;
    })

    (lib.mkIf (cfg.channel != "nixpkgs") (
      let
        toolchain = (rust-overlay.lib.mkRustBin { } pkgs.buildPackages)."${cfg.channel}"."${cfg.version}";
        filteredToolchain = (lib.filterAttrs (n: _: builtins.elem n toolchain._manifest.profiles.complete) toolchain);
      in
      {
        languages.rust.toolchain =
          (builtins.mapAttrs (_: pkgs.lib.mkDefault) filteredToolchain);

        packages = [
          (combine "rust-mixed" (
            (map (c: cfg.toolchain.${c}) (cfg.components ++ [ "rust-std" ])) ++
            (map (t: toolchain._components.${t}.rust-std) cfg.targets)
          ))
        ];
      }
    ))

    (lib.mkIf (cfg.import != { }) {
      # Apply cargo2nix overlay if not already applied
      overlays = [ cargo2nix.overlays.default ];

      # Create cargo2nix tasks for each import
      tasks = lib.mapAttrs'
        (name: importCfg:
          lib.nameValuePair "cargo2nix:${name}" {
            exec = ''
              echo "Generating Cargo.nix for ${name}..."
              ${cargo2nix.packages.${pkgs.system}.default}/bin/cargo2nix ${toString importCfg.root}
            '';
            description = "Generate Cargo.nix for ${name} project";
          }
        )
        cfg.import;
    })
  ]);
}
