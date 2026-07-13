{
  description = "Build Environment: slickback";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [

          # compilation
          gnumake
          gcc
          binutils
          ncurses
          bison
          flex
          openssl
          elfutils
          bc
          perl
          python3
          pkg-config

          # rootFS and initramfs
          cpio
          gzip

          # bootloader and ISO
          xorriso
          grub2
          mtools
          squashfsTools

          # test
          qemu

          # tools
          wget
          curl
          git
        ];

        shellHook = ''
          echo "=== Build Environment ==="
          echo "GCC: $(gcc --version | head -1)"
          echo "Kernel target: 6.18.38 LTS"
          echo ""
          echo "commands:"
          echo "  make defconfig    - base config"
          echo "  make menuconfig   - interactive config"
          echo "  make -j$(nproc)   - compile kernel"
        '';
      };
    };
}
