{
  lib,
  python,
  namePrefix,
  toPythonModule,
}:
let
  inherit (builtins)
    elem
    unsafeGetAttrPos
    ;
  inherit (lib)
    extendDerivation
    fixedWidthString
    flip
    getName
    isBool
    max
    optionalString
    removeAttrs
    removePrefix
    stringLength
    ;
in
rec {
  cleanAttrs = flip removeAttrs [
    "disabled"
    "checkPhase"
    "checkInputs"
    "nativeCheckInputs"
    "doCheck"
    "doInstallCheck"
    "pyproject"
    "format"
    "disabledTestPaths"
    "disabledTests"
    "pytestFlags"
    "pytestFlagsArray"
    "unittestFlags"
    "unittestFlagsArray"
    "outputs"
    "stdenv"
    "dependencies"
    "optional-dependencies"
    "build-system"
  ];
  leftPadName =
    name: against:
    let
      len = max (stringLength name) (stringLength against);
    in
    fixedWidthString len " " name;

  # This derivation transformation function must be independent to `attrs`
  # for fixed-point arguments support in the future.
  transformDrv =
    drv:
    extendDerivation (
      drv.disabled
      -> throw "${removePrefix namePrefix drv.name} not supported for interpreter ${python.executable}"
    ) { } (toPythonModule drv);
  computeFormat =
    { pyproject, format }:
    assert (pyproject != null) -> (format == null);
    if pyproject != null then
      if pyproject then "pyproject" else "other"
    else if format != null then
      format
    else
      "setuptools";
  withDistOutput' = flip elem [
    "pyproject"
    "setuptools"
    "wheel"
  ];
  isPythonModule =
    drv:
    # all pythonModules have the pythonModule attribute
    (drv ? "pythonModule")
    # Some pythonModules are turned in to a pythonApplication by setting the field to false
    && (!isBool drv.pythonModule);
  isMismatchedPython = drv: drv.pythonModule != python;

  mkValidatePythonMatches =
    attrs: finalAttrs:
    let
      throwMismatch =
        attrName: drv:
        let
          myName = "'${finalAttrs.name}'";
          theirName = "'${drv.name}'";
          optionalLocation =
            let
              pos = unsafeGetAttrPos (if attrs ? "pname" then "pname" else "name") attrs;
            in
            optionalString (pos != null) " at ${pos.file}:${toString pos.line}:${toString pos.column}";
        in
        throw ''
          Python version mismatch in ${myName}:

          The Python derivation ${myName} depends on a Python derivation
          named ${theirName}, but the two derivations use different versions
          of Python:

              ${leftPadName myName theirName} uses ${python}
              ${leftPadName theirName myName} uses ${toString drv.pythonModule}

          Possible solutions:

            * If ${theirName} is a Python library, change the reference to ${theirName}
              in the ${attrName} of ${myName} to use a ${theirName} built from the same
              version of Python

            * If ${theirName} is used as a tool during the build, move the reference to
              ${theirName} in ${myName} from ${attrName} to nativeBuildInputs

            * If ${theirName} provides executables that are called at run time, pass its
              bin path to makeWrapperArgs:

                  makeWrapperArgs = [ "--prefix PATH : ''${lib.makeBinPath [ ${getName drv} ] }" ];

          ${optionalLocation}
        '';

      checkDrv =
        attrName: drv:
        if (isPythonModule drv) && (isMismatchedPython drv) then throwMismatch attrName drv else drv;

    in
    attrName: inputs: map (checkDrv attrName) inputs;
}
