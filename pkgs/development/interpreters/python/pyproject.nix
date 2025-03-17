import (
  builtins.fetchTarball {
  url = "https://github.com/SomeoneSerge/pyproject.nix/archive/075efd01f4e5e0252659b1d65fc48fdd7e009c92.tar.gz";
    sha256 = "sha256:0q06wh4qv5d9zwcv93jcpmvf6g95f44ihywk153nbwlhlcl82pfl";
  }
) { lib = import ../../../../lib; }
