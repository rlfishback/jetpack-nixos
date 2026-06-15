{ applyPatches
, bspSrc
, gitRepos
, kernel
, l4tMajorMinorPatchVersion
, lib
, runCommand
, stdenv
, buildPackages
, ...
}:
let
  patchedT23xPublicDts = applyPatches {
    name = "t23x-public-dts";
    src = gitRepos."hardware/nvidia/t23x/nv-public";
    patches = [
      ./patches/t23x-public-dts/0001-imx708-v4l2-add-camera-overlay.patch
    ];
  };

  patchedGitRepos = gitRepos // {
    "hardware/nvidia/t23x/nv-public" = patchedT23xPublicDts;
  };

  l4t-devicetree-sources = runCommand "l4t-devicetree-sources" { }
    (lib.strings.concatStrings
      ([ "mkdir -p $out ; cp ${bspSrc}/source/Makefile $out/Makefile ;" ] ++
        lib.lists.forEach
          [ "hardware/nvidia/t23x/nv-public" "hardware/nvidia/tegra/nv-public" "kernel-devicetree" ]
          (
            project:
            ''
              mkdir -p "$out/${project}"
              cp --no-preserve=all -vr "${lib.attrsets.attrByPath [project] 0 patchedGitRepos}"/. "$out/${project}"
            ''
          )));
in
stdenv.mkDerivation (finalAttrs: {
  pname = "l4t-devicetree";
  version = "${l4tMajorMinorPatchVersion}";
  src = l4t-devicetree-sources;

  __structuredAttrs = true;
  strictDeps = true;

  inherit kernel;

  nativeBuildInputs = finalAttrs.kernel.moduleBuildDependencies;
  depsBuildBuild = [ buildPackages.stdenv.cc ];

  # See bspSrc/source/Makefile
  makeFlags = [
    "KERNEL_HEADERS=${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/source"
    "KERNEL_OUTPUT=${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/build"
  ];

  buildFlags = "dtbs";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"/
    # See kernel-devicetree/generic-dts/Makefile
    # The dtbs are installed to kernel-devicetree/generic-dts/dtbs
    install -Dm644 kernel-devicetree/generic-dts/dtbs/* "$out/"

    runHook postInstall
  '';
})
