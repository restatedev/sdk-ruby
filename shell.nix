{ pkgs ? import <nixpkgs> {} }:

let
  # Ruby 4.0.10 fixes the regexp/string vulnerabilities announced 2026-11-18
  # (https://www.ruby-lang.org/en/news/2026/11/18/multiple-vulnerabilities-in-regexp-and-string/).
  # nixpkgs bumped it in NixOS/nixpkgs@3b123ac; until that reaches the channel,
  # build it here with the same hashes. Drop this once pkgs.ruby_4_0.version >= 4.0.10.
  ruby_4_0 =
    if pkgs.lib.versionAtLeast (toString pkgs.ruby_4_0.version) "4.0.10" then pkgs.ruby_4_0
    else pkgs.mkRuby {
      version = pkgs.mkRubyVersion "4" "0" "10" "";
      hash = "sha256-tT7vM3H6XT47dDQO3NAV8G1diFOWjU5TmlJk/OQe2fE=";
      cargoHash = "sha256-z7NwWc4TaR042hNx0xgRkh/BQEpEJtE53cfrN0qNiE0=";
    };
in
with pkgs; mkShell {
  name = "sdk-ruby";
  buildInputs = [
    # Ruby (bundler ships with Ruby itself, so it matches the interpreter)
    ruby_4_0

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
    #biome
    #    watchman
  ];

  LIBCLANG_PATH = pkgs.lib.makeLibraryPath [ pkgs.llvmPackages_latest.libclang.lib ];

  shellHook = ''
    export GEM_HOME="$PWD/.gem"
    export PATH="$GEM_HOME/bin:$PATH"
    export BUNDLE_PATH="$PWD/.bundle"
  '';
}
