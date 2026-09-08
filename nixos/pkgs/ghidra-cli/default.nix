# ghidra-cli — a Rust CLI that drives Ghidra headless, for reverse engineering
# with an agent in the loop. Upstream ships no Nix packaging, so this is ours.
#
# Why it is wrapped rather than just built: upstream expects you to run
# `ghidra setup` to download a Ghidra tarball and then point at it with
# GHIDRA_INSTALL_DIR. On NixOS that is the wrong shape -- nixpkgs already has
# Ghidra, and a downloaded tarball would need its interpreter patched to run
# at all. The wrapper pins both halves of the runtime instead:
#
#   GHIDRA_INSTALL_DIR   nixpkgs' ghidra (12.1.2), the version upstream wants
#   JAVA_HOME            a full JDK, not a JRE -- Ghidra compiles the bridge
#                        script at runtime, so it needs javac and the
#                        jdk.compiler module. Ghidra 12.x wants JDK 21.
#
# Both are overridable on the command line (--java-home) or in the tool's own
# config, so the wrapper sets a working default without taking the choice away.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  makeWrapper,
  pkg-config,
  openssl,
  ghidra,
  jdk21,
}:

rustPlatform.buildRustPackage rec {
  pname = "ghidra-cli";
  version = "0.2.2-unstable-2026-08-08";

  src = fetchFromGitHub {
    owner = "akiselev";
    repo = "ghidra-cli";
    rev = "10019ba1f3b54c9edcca8ec644a30e16fb7b7c79";
    hash = "sha256-B4bnOOFtEsckT5TOAmjbx5AkrdpjeA248G+BrDUHY88=";
  };

  # Pinned by the lock file rather than a cargoHash: every dependency is a
  # crates.io registry entry, so this needs no vendoring hash that would go
  # stale on its own. Refresh this file whenever rev moves.
  cargoLock.lockFile = ./Cargo.lock;

  # reqwest is asked for rustls-tls, but cargo features are additive and its
  # defaults still pull in default-tls, so openssl-sys comes along and wants
  # pkg-config. Only the `setup` subcommand's downloads use it.
  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];
  buildInputs = [ openssl ];

  # The test suite drives a real Ghidra install and expects to bind sockets.
  doCheck = false;

  postInstall = ''
    wrapProgram $out/bin/ghidra \
      --set-default GHIDRA_INSTALL_DIR ${ghidra}/lib/ghidra \
      --set-default JAVA_HOME ${jdk21.home} \
      --prefix PATH : ${lib.makeBinPath [ jdk21 ]}
  '';

  meta = {
    description = "Rust CLI to run Ghidra headless for reverse engineering";
    homepage = "https://github.com/akiselev/ghidra-cli";
    license = lib.licenses.gpl3Only;
    mainProgram = "ghidra";
    platforms = lib.platforms.linux;
  };
}
