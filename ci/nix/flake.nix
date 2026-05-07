{
  description = "Fork-only Neovim macOS CI dependency shell experiment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems =
        f:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = f system;
          }) systems
        );

      shellFor =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          python = pkgs.python3.withPackages (ps: [ ps.pynvim ]);
          perl = pkgs.perl.withPackages (ps: [
            ps.Appcpanminus
            ps.NeovimExt
          ]);
          ruby = pkgs.bundlerEnv {
            name = "neovim-ruby-env";
            gemdir = "${nixpkgs}/pkgs/applications/editors/neovim/ruby_provider";
            postBuild = ''
              ln -sf ${pkgs.ruby}/bin/* $out/bin
            '';
          };
        in
        pkgs.mkShellNoCC {
          packages = [
            pkgs.cmake
            pkgs.fish
            pkgs.fswatch
            pkgs.gnumake
            pkgs.gettext
            pkgs.libiconv
            pkgs.neovim-node-client
            pkgs.ninja
            pkgs.nodejs
            pkgs.pkg-config
            perl
            python
            ruby
          ];

          shellHook = ''
            export CMAKE_PREFIX_PATH="${pkgs.gettext}:${pkgs.lib.getDev pkgs.libiconv}:${pkgs.libiconv}''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
            : "''${NIX_NPM_PREFIX:=''${RUNNER_TEMP:-$PWD/.nix-devshell}/npm}"
            export NPM_CONFIG_PREFIX="$NIX_NPM_PREFIX"
            export npm_config_prefix="$NPM_CONFIG_PREFIX"
            mkdir -p "$NPM_CONFIG_PREFIX/lib/node_modules"
            ln -sfn ${pkgs.neovim-node-client}/lib/node_modules/neovim/packages/neovim "$NPM_CONFIG_PREFIX/lib/node_modules/neovim"
            export NODE_PATH="$NPM_CONFIG_PREFIX/lib/node_modules''${NODE_PATH:+:$NODE_PATH}"
            export NIX_NEOVIM_CI_SHELL=1
          '';
        };
    in
    {
      devShells = forAllSystems (system: {
        default = shellFor system;
        macos-ci = shellFor system;
      });
    };
}
