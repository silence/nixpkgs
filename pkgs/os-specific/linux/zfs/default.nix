{ stdenv, fetchFromGitHub, autoreconfHook, utillinux, nukeReferences, coreutils, fetchpatch
, configFile ? "all"

# Userspace dependencies
, zlib, libuuid, python, attr

# Kernel dependencies
, kernel ? null, spl ? null, splUnstable ? null
}:

with stdenv.lib;
let
  buildKernel = any (n: n == configFile) [ "kernel" "all" ];
  buildUser = any (n: n == configFile) [ "user" "all" ];

  common = { version, sha256, extraPatches, spl, inkompatibleKernelVersion ? null } @ args:
    if buildKernel &&
       (inkompatibleKernelVersion != null) &&
       versionAtLeast kernel.version inkompatibleKernelVersion then
      throw "linux v${kernel.version} is not yet supported by zfsonlinux v${version}"
    else stdenv.mkDerivation rec {
      name = "zfs-${configFile}-${version}${optionalString buildKernel "-${kernel.version}"}";

      src = fetchFromGitHub {
        owner = "zfsonlinux";
        repo = "zfs";
        rev = "zfs-${version}";
        inherit sha256;
      };

      patches = extraPatches;

      buildInputs = [ autoreconfHook nukeReferences ]
      ++ optionals buildKernel [ spl ]
      ++ optionals buildUser [ zlib libuuid python attr ];

      # for zdb to get the rpath to libgcc_s, needed for pthread_cancel to work
      NIX_CFLAGS_LINK = "-lgcc_s";

      hardeningDisable = [ "pic" ];

      preConfigure = ''
        substituteInPlace ./module/zfs/zfs_ctldir.c   --replace "umount -t zfs"           "${utillinux}/bin/umount -t zfs"
        substituteInPlace ./module/zfs/zfs_ctldir.c   --replace "mount -t zfs"            "${utillinux}/bin/mount -t zfs"
        substituteInPlace ./lib/libzfs/libzfs_mount.c --replace "/bin/umount"             "${utillinux}/bin/umount"
        substituteInPlace ./lib/libzfs/libzfs_mount.c --replace "/bin/mount"              "${utillinux}/bin/mount"
        substituteInPlace ./udev/rules.d/*            --replace "/lib/udev/vdev_id"       "$out/lib/udev/vdev_id"
        substituteInPlace ./cmd/ztest/ztest.c         --replace "/usr/sbin/ztest"         "$out/sbin/ztest"
        substituteInPlace ./cmd/ztest/ztest.c         --replace "/usr/sbin/zdb"           "$out/sbin/zdb"
        substituteInPlace ./config/user-systemd.m4    --replace "/usr/lib/modules-load.d" "$out/etc/modules-load.d"
        substituteInPlace ./config/zfs-build.m4       --replace "\$sysconfdir/init.d"     "$out/etc/init.d"
        substituteInPlace ./etc/zfs/Makefile.am       --replace "\$(sysconfdir)"          "$out/etc"
        substituteInPlace ./cmd/zed/Makefile.am       --replace "\$(sysconfdir)"          "$out/etc"
        substituteInPlace ./module/Makefile.in        --replace "/bin/cp"                 "cp"
        substituteInPlace ./etc/systemd/system/zfs-share.service.in \
          --replace "@bindir@/rm " "${coreutils}/bin/rm "
        ./autogen.sh
      '';

      configureFlags = [
        "--with-config=${configFile}"
        ] ++ optionals buildUser [
        "--with-dracutdir=$(out)/lib/dracut"
        "--with-udevdir=$(out)/lib/udev"
        "--with-systemdunitdir=$(out)/etc/systemd/system"
        "--with-systemdpresetdir=$(out)/etc/systemd/system-preset"
        "--with-mounthelperdir=$(out)/bin"
        "--sysconfdir=/etc"
        "--localstatedir=/var"
        "--enable-systemd"
        ] ++ optionals buildKernel [
        "--with-spl=${spl}/libexec/spl"
        "--with-linux=${kernel.dev}/lib/modules/${kernel.modDirVersion}/source"
        "--with-linux-obj=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
      ];

      enableParallelBuilding = true;

      installFlags = [
        "sysconfdir=\${out}/etc"
        "DEFAULT_INITCONF_DIR=\${out}/default"
      ];

      postInstall = ''
        # Prevent kernel modules from depending on the Linux -dev output.
        nuke-refs $(find $out -name "*.ko")
      '' + optionalString buildUser ''
        # Remove provided services as they are buggy
        rm $out/etc/systemd/system/zfs-import-*.service

        sed -i '/zfs-import-scan.service/d' $out/etc/systemd/system/*

        for i in $out/etc/systemd/system/*; do
        substituteInPlace $i --replace "zfs-import-cache.service" "zfs-import.target"
        done

        # Fix pkgconfig.
        ln -s ../share/pkgconfig $out/lib/pkgconfig

        # Remove tests because they add a runtime dependency on gcc
        rm -rf $out/share/zfs/zfs-tests
      '';

      meta = {
        description = "ZFS Filesystem Linux Kernel module";
        longDescription = ''
          ZFS is a filesystem that combines a logical volume manager with a
          Copy-On-Write filesystem with data integrity detection and repair,
          snapshotting, cloning, block devices, deduplication, and more.
        '';
        homepage = http://zfsonlinux.org/;
        license = licenses.cddl;
        platforms = platforms.linux;
        maintainers = with maintainers; [ jcumming wizeman wkennington fpletz ];
      };
    };
in
  assert any (n: n == configFile) [ "kernel" "user" "all" ];
  assert buildKernel -> kernel != null && spl != null;
  {
    # also check if kernel version constraints in
    # ./nixos/modules/tasks/filesystems/zfs.nix needs
    # to be adapted
    zfsStable = common {
      # comment/uncomment if breaking kernel versions are known
      inkompatibleKernelVersion = "4.9";

      version = "0.6.5.8";

      # this package should point to the latest release.
      sha256 = "0qccz1832p3i80qlrrrypypspb9sy9hmpgcfx9vmhnqmkf0yri4a";
      extraPatches = [
        (fetchpatch {
          url = "https://github.com/Mic92/zfs/compare/zfs-0.6.5.8...nixos-zfs-0.6.5.8.patch";
          sha256 = "14kqqphzg02m9a7qncdhff8958cfzdrvsid3vsrm9k75lqv1w08z";
        })
      ];
      inherit spl;
    };
    zfsUnstable = common {
      # comment/uncomment if breaking kernel versions are known
      inkompatibleKernelVersion = "4.10";

      version = "0.7.0-rc2";

      # this package should point to a version / git revision compatible with the latest kernel release
      sha256 = "197y2jyav9h1ksri9kzqvrwmzpb58mlgw27vfvgd4bvxpwfxq53s";
      extraPatches = [
        (fetchpatch {
          url = "https://github.com/Mic92/zfs/compare/zfs-0.7.0-rc2...nixos-zfs-0.7.0-rc2.patch";
          sha256 = "1p33bwd6p5r5phbqb657x8h9x3bd012k2mdmbzgnb09drh9v0r82";
        })
        (fetchpatch {
          name = "Kernel_4.9_zfs_aio_fsync_removal.patch";
          url = "https://github.com/zfsonlinux/zfs/commit/99ca173929cb693012dabe98bcee4f12ec7e6e92.patch";
          sha256 = "10npvpj52rpq88vdsn7zkdhx2lphzvqypsd9abdadjbqkwxld9la";
        })
      ];
      spl = splUnstable;
    };
  }
