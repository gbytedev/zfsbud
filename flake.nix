{
  description = "A nix flake for the zfsbud script";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.zfsbud = nixpkgs.legacyPackages.x86_64-linux.stdenv.mkDerivation {
      pname = "zfsbud";
      src = self;
      buildInputs = [ nixpkgs.legacyPackages.x86_64-linux.bash ];
      dontBuild = true;
      installPhase = ''
        install -D ${pname}.sh $out/bin/${pname}
        install -D default.zfsbud.conf $out/bin/default.zfsbud.conf
        wrapProgram $out/bin/${pname} \
          --prefix PATH : ${nixpkgs.lib.makeBinPath [ /* list of dependencies */ ]}
      '';
    };

    defaultPackage.x86_64-linux = self.packages.x86_64-linux.zfsbud;
  };
} 
