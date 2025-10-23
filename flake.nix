{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    ghc-wasm-meta = {
      url = "gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-compat.url = "github:nix-community/flake-compat";
  };

  outputs = inputs:
    with builtins;
    let
      inherit (inputs.nixpkgs) lib;
      foreach = xs: f: with lib; foldr recursiveUpdate { } (
        if isList xs then map f xs
        else if isAttrs xs then mapAttrsToList f xs
        else throw "foreach: expected list or attrset but got ${typeOf xs}"
      );
      ghc = "ghc9122";
      targetPrefix = "wasm32-wasi-";
      wasmPkgs = system: import inputs.nixpkgs rec {
        inherit system;
        crossSystem = lib.systems.elaborate lib.systems.examples.wasi32 // {
          isStatic = false;
        };
        config.replaceCrossStdenv = { buildPackages, baseStdenv }: buildPackages.stdenvNoCC.override {
          inherit (baseStdenv)
            buildPlatform
            hostPlatform
            targetPlatform;
          cc = inputs.ghc-wasm-meta.packages.${system}.all_9_12 // {
            isGNU = false;
            isClang = true;
            libc = inputs.ghc-wasm-meta.packages.${system}.wasi-sdk.overrideAttrs (attrs: { pname = attrs.name; version = "unstable1"; });
            inherit targetPrefix;
            bintools = inputs.ghc-wasm-meta.packages.${system}.all_9_12 // {
              inherit targetPrefix;
              bintools = inputs.ghc-wasm-meta.packages.${system}.all_9_12 // {
                inherit targetPrefix;
              };
            };
          };
        };
        crossOverlays = [
          (final: prev: {
            cabal-install = inputs.ghc-wasm-meta.packages.${system}.wasm32-wasi-cabal-9_12;
            haskell = prev.haskell.override (old: {
              buildPackages = lib.recursiveUpdate old.buildPackages {
                haskell.compiler.${ghc} = inputs.ghc-wasm-meta.packages.${system}.wasm32-wasi-ghc-9_12 // {
                  inherit targetPrefix;
                };
              };
            });
          })
          (final: prev: {
            haskell = prev.haskell // {
              packageOverrides = lib.composeManyExtensions [
                prev.haskell.packageOverrides
                (hfinal: hprev: {
                  mkDerivation = args: (hprev.mkDerivation (args // {
                    enableLibraryProfiling = false;
                    enableSharedLibraries = true;
                    enableStaticLibraries = false;
                    doBenchmark = false;
                    doCheck = false;
                    jailbreak = true;
                    configureFlags = [
                      "--with-ld=${prev.stdenv.cc.bintools}/bin/lld"
                      "--with-ar=${prev.stdenv.cc.bintools}/bin/ar"
                      "--with-strip=${prev.stdenv.cc.bintools}/bin/strip"
                    ];
                    #buildFlags = (args.buildFlags or []) ++ ["-v3"];
                    setupHaskellDepends = (args.setupHaskellDepends or []) ++ [
                      # This executes the wasi-sdk setup-hook that sets toolchain env vars such as AR, CC, ...
                      inputs.ghc-wasm-meta.packages.${system}.wasi-sdk
                    ];
                    preBuild = ''
                      ${args.preBuild or ""}
                      export NIX_CC=$CC
                    '';
                  })).overrideAttrs (attrs: {
                    name = "${attrs.pname}-${targetPrefix}${attrs.version}";
                    preSetupCompilerEnvironment = ''
                      export CC_FOR_BUILD=$CC
                    '';
                  });
                })
              ];
            };
          })
        ];
      };
    in
    foreach inputs.nixpkgs.legacyPackages (system: pkgs:
      let
        wasmPackages = wasmPkgs system;
        haskellPackages = wasmPackages.haskell.packages.${ghc};
      in {
        legacyPackages.${system} = wasmPackages // {
          inherit haskellPackages;
        };
        packages.${system}.default = haskellPackages.rhine;
        devShells.${system}.default = pkgs.mkShell {
          buildInputs = [
            (inputs.ghc-wasm-meta.packages.${system}.all_9_12)
          ];
          env.NIXPKGS_ALLOW_BROKEN = "1";
        };
      }
    );
}
