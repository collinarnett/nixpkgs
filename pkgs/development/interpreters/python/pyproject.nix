import (
  builtins.fetchTarball {
    url = "https://github.com/SomeoneSerge/pyproject.nix/archive/60b3aa0c0093bcfbb60bde37afc38e8f50915e73.tar.gz";
    sha256 = "0w21qpf5wgl8x4533ncip9gj00y78sr7j80s5jvr2sq22b015sgb";
  }
) { lib = import ../../../../lib; }
