{
  description = "Personal knowledge base";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Encryption + infra
            age
            direnv
            opentofu
            ansible
            just

            # Process management
            pm2

            # Bot development
            elixir_1_17
            erlang_27
            sqlite
            gcc
            pkg-config
            nodejs_22
          ];

          shellHook = ''
            export MIX_HOME="$PWD/kbase_bot/.nix-mix"
            export HEX_HOME="$PWD/kbase_bot/.nix-hex"
            export ERL_AFLAGS="-kernel shell_history enabled"
            mkdir -p "$MIX_HOME" "$HEX_HOME"
            export PATH="$MIX_HOME/bin:$MIX_HOME/escripts:$PATH"
            export PATH="$PWD/kbase_bot/node_modules/.bin:$PATH"

            # Install qmd if not present
            if [ ! -f kbase_bot/node_modules/.bin/qmd ]; then
              echo "Installing qmd..."
              cd kbase_bot && npm install @tobilu/qmd && cd ..
            fi
          '';
        };
      });
}
