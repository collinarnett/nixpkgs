{
  namePrefix,
  toPythonModule,
  resolveBuildSystem,
  pyprojectHook,
  lib,
  python,
  setuptools, # TODO: check if this is spliced?
  wheel,
}:

let
  inherit (lib)
    optionals
    optionalAttrs
    ;
  util = import ./util.nix {
    inherit
      lib
      toPythonModule
      namePrefix
      python
      ;
  };
in

{
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  checkInputs ? [ ],
  nativeCheckInputs ? [ ],
  propagatedBuildInputs ? [ ],
  dependencies ? [ ],
  optional-dependencies ? { },
  build-system ? [ ],
  pythonPath ? null,
  strictDeps ? true,
  outputs ? [ "out" ],
  disabled ? false,
  catchConflicts ? null,
  makeWrapperArgs ? null,
  dontWrapPythonPrograms ? null,
  dontUsePipInstall ? null,
  permitUserSite ? null,
  removeBinBytecode ? true,
  pyproject ? null,
  format ? null,
  meta ? { },
  doCheck ? true,
  disabledTestPaths ? [ ],
  stdenv ? python.stdenv,
  ...
}@attrs:

# Out of scope
assert catchConflicts == null;
assert makeWrapperArgs == null;
assert dontWrapPythonPrograms == null;
assert dontUsePipInstall == null;
assert permitUserSite == null;
assert pythonPath == null;

let
  inherit (util)
    cleanAttrs
    withDistOutput
    computeFormat
    transformDrv
    isBootstrapInstallPackage'
    isBootstrapPackage'
    ;
  isBootstrapInstallPackage = isBootstrapInstallPackage' (attrs.pname or null);

  isBootstrapPackage = isBootstrapInstallPackage || isBootstrapPackage' (attrs.pname or null);
  inputsToRequirements =
    xs:
    lib.listToAttrs (
      map (
        p:
        lib.nameValuePair
          #
          (p.__lateBindingAttrName or p.pname)
          (p.__lateBindingExtras or [ ])
      ) xs
    );
  drv = stdenv.mkDerivation (
    finalAttrs:
    let
      format' = computeFormat { inherit pyproject format; };
      inherit (util)
        mkValidatePythonMatches
        withDistOutput'
        isWeird
        ;
      validatePythonMatches = mkValidatePythonMatches attrs finalAttrs;

      withDistOutput = withDistOutput' format';

      build-system' = if build-system == [ ] && !isBootstrapPackage then [ setuptools wheel ] else [ ];
    in
    cleanAttrs attrs
    // {
      name = namePrefix + attrs.name or "${finalAttrs.pname}-${finalAttrs.version}";
      nativeBuildInputs =
        [
          pyprojectHook
        ]
        ++ nativeBuildInputs
        #
        ++ optionals (!(isWeird finalAttrs.pname)) (
          resolveBuildSystem (inputsToRequirements build-system')
        );
      buildInputs = validatePythonMatches "buildInputs" buildInputs;
      propagatedBuildInputs = validatePythonMatches "propagatedBuildInputs" (
        propagatedBuildInputs ++ [ python ]
      );
      inherit strictDeps;
      LANG = "${if stdenv.hostPlatform.isDarwin then "en_US" else "C"}.UTF-8";
      doCheck = false;
      doInstallCheck = false; # do a separate derivation!
      passthru = {
        inherit disabled;

        # We're not running tests so...
        nativeInstallCheckInputs = nativeCheckInputs;
        installCheckInputs = checkInputs;

        dependencies = inputsToRequirements dependencies;
        optional-dependencies = inputsToRequirements optional-dependencies;
        build-system = inputsToRequirements build-system;
      } // attrs.passthru or { };
      meta = {
        # default to python's platforms
        platforms = python.meta.platforms;
        isBuildPythonPackage = python.meta.platforms;
      } // meta;
    }
    // optionalAttrs (attrs.doCheck or true) (
      optionalAttrs (disabledTestPaths != [ ]) {
        disabledTestPaths = disabledTestPaths;
      }
      // optionalAttrs (attrs ? disabledTests) {
        disabledTests = attrs.disabledTests;
      }
      // optionalAttrs (attrs ? pytestFlags) {
        pytestFlags = attrs.pytestFlags;
      }
      // optionalAttrs (attrs ? pytestFlagsArray) {
        pytestFlagsArray = attrs.pytestFlagsArray;
      }
      // optionalAttrs (attrs ? unittestFlags) {
        unittestFlags = attrs.unittestFlags;
      }
      // optionalAttrs (attrs ? unittestFlagsArray) {
        unittestFlagsArray = attrs.unittestFlagsArray;
      }
    )
  );
in
transformDrv drv
