{
  description = "A nix flake for the zfsbud script";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.zfsbud = nixpkgs.legacyPackages.x86_64-linux.stdenv.mkDerivation {
      pname = "zfsbud";
      version = "master";
      src = self;
      buildInputs = [ nixpkgs.legacyPackages.x86_64-linux.bash ];
      dontBuild = true;
      installPhase = ''
        install -D zfsbud.sh $out/bin/zfsbud
        install -D default.zfsbud.conf $out/bin/default.zfsbud.conf
        wrapProgram $out/bin/zfsbud \
          --prefix PATH : ${nixpkgs.lib.makeBinPath [ /* list of dependencies */ ]}
      '';
    };

    packages.x86_64-linux.default = self.packages.x86_64-linux.zfsbud;
  };
} 
