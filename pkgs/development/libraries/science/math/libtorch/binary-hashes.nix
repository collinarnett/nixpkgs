version:
builtins.getAttr version {
  "2.7.1" = {
    aarch64-darwin-cpu = {
      name = "libtorch-macos-arm64-2.7.1.zip";
      url = "https://download.pytorch.org/libtorch/cpu/libtorch-macos-arm64-2.7.1.zip";
      sha256 = "sha256-T4efoULjgO7lEnL2OPgJtZF0LMePQhammLrWL6dy8UY=";
    };
    x86_64-linux-cpu = {
      name = "libtorch-cxx11-abi-shared-with-deps-2.7.1-cpu.zip";
      url = "https://download.pytorch.org/libtorch/cpu/libtorch-cxx11-abi-shared-with-deps-2.7.1%2Bcpu.zip";
      sha256 = "sha256-+FXvNaPRN2A+4p6VuAXHjyvOCbtZ6042K8iG+ZPUne0=";
    };
    x86_64-linux-cuda = {
      name = "libtorch-cxx11-abi-shared-with-deps-2.7.1-cu128.zip";
      url = "https://download.pytorch.org/libtorch/cu128/libtorch-cxx11-abi-shared-with-deps-2.7.1%2Bcu128.zip";
      sha256 = "sha256-0E+ISNOjQFZQ6f22UtPoXSh/BL3AeWI0baY74EkStfo=";
    };
  };
}
