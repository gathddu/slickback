# Slickback

A from-scratch Linux distribution built as part of the Monitoria Workshop. This log documents my process on NixOS, which differs significantly from the Ubuntu-based instructions.

---

## Setup

### The Problem with NixOS

Most Linux From Scratch guides assume that you're on Ubuntu/Debian/Fedora where you run `apt install build-essential` and everything "just works". NixOS is different:

- Packages are stored in `/nix/store/` with hashed paths, not in `/usr/lib/` or `/usr/include/`
- There is no `/usr/include/ncurses.h` - it lives in `/nix/store/bavw0x...-ncurses-6.6-dev/include/ncurses.h`
-There is no global `LD_LIBRARY_PATH` - the linker doesn't know where libraries are unless you tell it
- Static libraries (`.a` files) are NOT included by default - NixOS only ships shared (`.so`) unless you explicitly request static

This means every build system that does "can I find library X?" checks will fail on NixOS unless you set up the environment correctly.

### Solution

Instead of polluting the system with globally installed packages, I used a Nix Flake - a declarative, reproducible, isolated build environment.

```nix
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
          ncurses.dev
          bison
          flex
          openssl
          elfutils
          bc
          perl
          python3
          pkg-config

	 # rootFS and initramfs
	 glibc.static
          cpio
          gzip

	 # bootloader and ISO
          xorriso
          grub2
          mtools
          squashfsTools

	 # tools
          qemu
          wget
          curl
          git
        ];

        shellHook = ''
  	 export PKG_CONFIG_PATH="${pkgs.ncurses.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  	 export CPATH="${pkgs.ncurses.dev}/include''${CPATH:+:$CPATH}"
  	 export LIBRARY_PATH="${pkgs.ncurses}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
  	 echo "=== Build Environment ==="
  	 echo "GCC: $(gcc --version | head -1)"
	'';
      };
    };
}
```

| Package | Why |
| ------- | --- |
| ncurses.dev | BusyBox and kernel menuconfig need ncurses header (ncurses.h). On NixOS, the runtime lib (ncurses) and the dev headers (ncurses.dev) are separate packages. Without .dev, you get the .so but not the .h. |
| glibc.static | BusyBox is compiled as a static binary (-static flag). Static linking needs .a archive filmes (libm.a, libresolv.a). NixOS only ships .so (shared) by default. Without this, the linker says "cannot find -lm". On Ubuntu, libc6-dev includes bboth .so and .a - NixOS separates them. |
| bison + flex | The kernel build system generates parsers for device tree and config files. Without these, make fails with "bison: command not found". |
| elfutils | Provides libelf which the kernel needs to process ELF binaries buring build (BTF generation, module signing). |
| bc | The kernel Makefile uses bc (calculator) to compute version numbers and sizes. |
| perl | Kernel build scripts (especially headers_install) are written in Perl. |

The PKG_CONFIG_PATH export tells pkg-config where to find .pc files for ncurses. Without it, pkg-config --libs ncursesw returns an error and any build system that uses pkg-config for ncurses detection fails.
The CPATH export tells GCC where to find headers without needing -I flags. It's a fallback for build systems that don't use pkg-config.
The LIBRARY_PATH export tells the linker where to find .so/.a files without needing -L flags.

#### Usage

```sh
cd ~/slickback
nix develop        # enter the build environment
# ... do the work here ...
exit               # leave (environment disappears)
```

The flake.lock file (auto-generated on first nix develop) pins the exact nixpkgs revision. This means if you clone this  repository on another NixOS machine in 6 months, nix develop gives you the exact same GCC version, same ncurses, same everything.

## Kernel

Kernel version: 6.18.38 LTS

The kernel versioning:

- Mainline: bleeding edge, released every ~2 months, may have bugs
- Stable: current release, gets fixes for a few weeks then abandoned
- Longterm/LTS: gets security fixes for 2-6 years

I wanted LTS because:

- If something breas, it's my fault (bad config, missing file), not a kernel bug
- The distribution is meant to be.. distributed - users expect stability
- Debugging is easier when you can eliminate "maybe it's a kernel regression" from the equation

I started using 6.1.x (older LTS) but it's from 2022. The kernel build system in 6.1.x uses C constructs that GCC 14+ (which NixOS unstable ships) treats as errors. I got compilation failures about -Werror flags and deprecated syntax. The kernel developers fixed these in newer versions. 6.18.38 compiles cleanly with modern GCC.

Another T.A. used 7.1.1 because he hit the same GCC issue with 6.1.x and grabbed the newest thing available. It works, but it's not LTS. It'll stop receiving updates in weeks. For learning purposes, it's fine. For a distributable distribution, LTS is the correct choice.

### Download and Extract

```sh
cd ~/slickback
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.38.tar.xz
tar -xvf linux-6.18.38.tar.xz
```

The source tree is ~1.3GB extracted but DON'T commit it!

```sh
echo "linux-*/" >> .gitignore
echo "*.tar.xz" >> .gitignore
```

### Configuration

```
cd linux-6.18.38
make defconfig
```

defconfig generates a .config file with ~2000 options pre-set for a generic x86_64 system. It includes:

- ELF binary support (so our BusyBox can run)
- Serial console support (so console=ttyS0 works in QEMU)
- Initramfs support (so the kernel can load our rootfs froma cpio archive)
- procfs, sysfs, devtmpfs (virtual filesystems out init script needs)
- Virtio drivers (QEMU's paravirtualized hardware)

I did not use menuconfig at this stage because there's nothing to change for a QEMU-only boot. The custom kernel config happens later when I target real hardware and need specific drivers (Wi-Fi chipset, GPU, Bluetooth).

### Compilation

```sh
make -j$(nproc)
```

-j$(nproc) runs as many parallel compile jobs as you have CPU cores. I have a 4-core machine, so it took ~15 minutes.

The output is `arch/x866/boot/bzImage`, the compressed kernel binary that bootloaders load into memory.

With defconfig, most drivers are compiled built-in, marked [\*] in menuconfig and not [M]. Built-in means the driver code is baked directly into bzImage. There are no separate .ko module files to install. I'll revisit this later to set drivers as modules [M] for dynamic loading.

## BusyBox

The kernel, once loaded, needs a userspace to hand control to. It looks for an init program (PID 1 ) in a filesystem. That filesystem needs:

- /sbin/init - the first process
- /bin/sh - a shell (so init can run scripts)
- Basic utilities (mount, ls, cat) - so the init scripts can set up the system
- Virtual filesystem mount points (/proc, /sys, /dev)

BusyBox provides all of it in a single ~2MB static binary.

### Download and Extract

```sh
cd ~/slickback
wget https://busybox.net/downloads/busybox-1.37.0.tar.bz2
tar -xvf busybox-1.37.0.tar.bz2
echo "busybox-*/" >> .gitignore
```

### Configuration

```sh
cd busybox-1.37.0
make defconfig
```

I needed to enable static linking:

```sh
make menuconfig
```

NixOS issue: menuconfig fails with "Unable to find ncurses"

BusyBox's menuconfig uses a script (scripts/kconfig/lxdialog/check-lxdialog.sh) to detect ncurses. This script:

1. Tries pkg-config --libs ncursesw (works because of the shellHook)
2. Gets the flags
3. Tries to compilea test program with #include CURSES_LOC where CURSES_LOC isa macro

Step 3 fails because of shell quoting issues when passing -DCURSES_LOC="<ncurses.h>" through multiple layers of shell expansion. The macro never gets defined properly in the test compilation.

Fix:

```sh
sed -i 's/exit 1/exit 0/' scripts/kconfig/lxdialog/check-lxdialog.sh
```

This makes the detection always pass. It's safe because I verified that GCC can compile with ncurses:

```sh
echo '#include <ncurses.h>
int main() {}' | gcc -x c - -o /tmp/test $(pkg-config --cflags --libs ncursesw)
# no error = ncurses works fine, the detection script is just broken on NixOS
```

After the fix, make menuconfig opens the TUI.

```menuconfig:
Settings --->
    [*] Build static binary (no shared libs)
```

The rootfs has no /lib/ directory with shared libraries. If BusyBox were dynamically linked, it would try to load libc.so.6 at runtime, fail to find it and crash with "No such file or directory" (a confusing error that looks like the binary itself is missing). Static = zero runtime dependencies = it just works.

```menuconfig:
Networking Utilities --->
    [ ] tc
```

The tc (traffic control) applet in BusyBox 1.37.0 references TCA_CBQ_* structs and struct tc_cbq_lssopt that were removed from kernel headers in 6.x. The CBQ (Class-Based Queueing) scheduler was deprecated and its header definitions deleted. BusyBox hasn't updated their tc code yet. Compilation fails with ~20 "undeclared identifier" errors. I'll compile full iproute2 instead, it has the real tc with modern schedulers (fq_codel, CAKE, HTB) which are actually useful for traffic shaping, network simulation and QoS.

### Compilation

```sh
make -j$(nproc)
```

NixOS issue: "cannotfind -lm: No such file or directory"

Static linking requires .a archive files (libm.a, libresolv.a), NixOS only ships shared libraries (.so) by default. The fix was adding glibc.static to the flake's buildInputs, which provides the static archives.

After adding glibc.static and re-entering nix develop:

```sh
make -j$(nproc)
```

### rootfs

```sh
make CONFIG_PREFIX=../rootfs install
```

It creates ~/slickback/rootfs/ with:

- bin/busybox = the actual binary (~2MB)
- bin/ls, bin/cat, bin/sh, etc. - symlinks to busybox
- sbin/init, sbin/reboot, sbin/mount, etc. - symlinks to busybox

When you run ls, the kernel executes bin/ls which isa symlink to bin/busybox.
Busybox checks argv\[0] (the name it was called), sees "ls" and runs its internal ls implementation. So, one binary, 300+ tools.
