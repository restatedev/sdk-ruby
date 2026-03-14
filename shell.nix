{ pkgs ? import <nixpkgs> {} }:

with pkgs; mkShell {
  name = "sdk-ruby";
  buildInputs = [
    # Ruby
    ruby_3_3
    bundler

    # Rust toolchain
    rustup
    cargo
    clang
    llvmPackages.bintools

    # Native build deps
    pkg-config
    openssl
    libyaml
    zlib

    # ide
    biome
    watchman
  ];

  LIBCLANG_PATH = pkgs.lib.makeLibraryPath [ pkgs.llvmPackages_latest.libclang.lib ];

  shellHook = ''
    export GEM_HOME="$PWD/.gem"
    export PATH="$GEM_HOME/bin:$PATH"
    export BUNDLE_PATH="$PWD/.bundle"
  '';
}
