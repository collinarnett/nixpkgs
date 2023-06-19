{ lib
, buildPythonPackage
, fetchFromGitHub
, pythonOlder
, # build deps
  filelock
, huggingface-hub
, importlib-metadata
, numpy
, pillow
, regex
, requests
, # quality
  black
, isort
, flake8
, ruff
, # training
  accelerate
, datasets
, protobuf
, tensorboard
, jinja2
, # tests
  k-diffusion
, librosa
, omegaconf
, parameterized
, pytest
, pytest-timeout
, pytest-xdist
, requests-mock
, safetensors
, sentencepiece
, scipy
, torchvision
, transformers
, torch
, jax
, jaxlib
, flax
,
}:
buildPythonPackage rec {
  pname = "diffusers";
  version = "0.17.1";
  disabled = pythonOlder "3.7";

  src = fetchFromGitHub {
    owner = "huggingface";
    repo = pname;
    rev = "refs/tags/v${version}";
    sha256 = "sha256-7u9bc0FaNoMBcwSfOCNPL0HtW2P0SZRVW84XZIl/LZg=";
  };

  propagatedBuildInputs = [
    filelock
    huggingface-hub
    importlib-metadata
    numpy
    pillow
    regex
    requests
  ];

  passthru.optional-dependencies = rec {
    quality = [
      black
      isort
      flake8
      ruff
      # hf-doc-builder
    ];
    training = [
      accelerate
      datasets
      protobuf
      tensorboard
      jinja2
    ];
    test = [
      # compel
      datasets
      jinja2
      k-diffusion
      librosa
      omegaconf
      parameterized
      pytest
      pytest-timeout
      pytest-xdist
      requests-mock
      safetensors
      sentencepiece
      scipy
      torchvision
      transformers
    ];
    torch_ = [
      torch
      accelerate
    ];
    jax_ = [
      jax
      jaxlib
      flax
    ];
    dev =
      quality
      ++ training
      ++ test
      ++ torch
      ++ jax;
  };

  # many tests require internet
  doCheck = false;

  pythonImportsCheck = [ "diffusers" ];

  meta = with lib; {
    homepage = "https://github.com/huggingface/diffusers";
    description = "Diffusion models for image and audio generation in PyTorch";
    changelog = "https://github.com/huggingface/diffusers/releases/tag/v${version}";
    license = licenses.asl20;
    platforms = platforms.unix;
    maintainers = with maintainers; [ collinarnett ];
  };
}
