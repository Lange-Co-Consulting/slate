# Third-party notices

Slate distributes the following third-party code or binaries. Release operators
must review this inventory whenever `Package.resolved`, a native XCFramework or
the packaged ripgrep release changes. The complete license texts are included in
the app under `Contents/Resources/ThirdPartyLicenses`.

| Distributed component | Version / artifact | Source | License |
| --- | --- | --- | --- |
| FluidAudio | 0.15.5 (`19600a485baa4998812e4654b70d2bab8f2c9949`) | https://github.com/FluidInference/FluidAudio | Apache-2.0 |
| fastcluster (via FluidAudio) | FluidAudio third-party source | https://github.com/fastcluster/fastcluster | BSD-3-Clause |
| VBx (via FluidAudio) | FluidAudio third-party source | https://github.com/BUTSpeechFIT/VBx | Apache-2.0 |
| llama.cpp | checksummed `llama.xcframework` | https://github.com/ggml-org/llama.cpp | MIT |
| stable-diffusion.cpp | checksummed `sd.xcframework` | https://github.com/leejet/stable-diffusion.cpp | MIT |
| ripgrep | 15.1.0 official Apple Silicon binary | https://github.com/BurntSushi/ripgrep | MIT OR Unlicense |
| PCRE2 (via ripgrep) | 10.45 | https://github.com/PCRE2Project/pcre2 | BSD-3-Clause WITH PCRE2-exception |
| swift-qwen3-tts | rev `27a5b5b` (SwiftPM) | https://github.com/AtomGradient/swift-qwen3-tts | MIT |
| MLX Swift (via swift-qwen3-tts) | SwiftPM | https://github.com/ml-explore/mlx-swift | MIT |
| MLX Swift Examples / MLXLMCommon (via swift-qwen3-tts) | SwiftPM | https://github.com/ml-explore/mlx-swift-examples | MIT |
| swift-transformers (via swift-qwen3-tts) | SwiftPM | https://github.com/huggingface/swift-transformers | Apache-2.0 |

## Model weights are not distributed with Slate

`Slate.app` contains no chat, image, speech-recognition, neural voice or VAD
model weights. The catalog only describes models. A model is stored on the Mac
after the user imports it or explicitly starts its download from its model host.
The downloaded file is not part of Slate's distribution and remains subject to
the license and terms shown by its provider.

This includes the optional Flow components NVIDIA Parakeet-TDT, Supertonic and
Silero VAD. Slate keeps their credits visible in the Flow/About UI, but does not
ship their model weights. The default read-aloud voice is an installed macOS
system voice and is not a model bundled by Slate.

## Curated optional model downloads

Slate offers direct links to the following provider-hosted files. They are not
inside `Slate.app`: the app shows the applicable licence and model card before
the user explicitly starts a download. Provider terms govern use of the
downloaded weights.

| Optional download | Provider source | Licence shown by Slate |
| --- | --- | --- |
| Qwen3.5 35B A3B GGUF | https://huggingface.co/unsloth/Qwen3.5-35B-A3B-GGUF | Apache-2.0 |
| Qwen3.5 9B GGUF | https://huggingface.co/unsloth/Qwen3.5-9B-GGUF | Apache-2.0 |
| SauerkrautLM v2 14B DPO GGUF | https://huggingface.co/mradermacher/SauerkrautLM-v2-14b-DPO-GGUF | Apache-2.0 |
| EuroLLM 9B Instruct GGUF | https://huggingface.co/bartowski/EuroLLM-9B-Instruct-GGUF | Apache-2.0 |
| Qwen-Image bundle | https://huggingface.co/QuantStack/Qwen-Image-GGUF | Apache-2.0 |
| NVIDIA Parakeet-TDT 0.6B v2 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 | CC-BY-4.0 |
| Supertone Supertonic | https://huggingface.co/Supertone/supertonic | OpenRAIL-M |
| Silero VAD | https://huggingface.co/BricksDisplay/silero-vad | MIT |
| Qwen3-TTS 0.6B CustomVoice edge build (premium voice) | https://huggingface.co/AtomGradient/Qwen3-TTS-0.6B-CustomVoice-4bit-pruned-vocab-lite | MIT (base model Apache-2.0) |

The catalog deliberately excludes models whose provider terms do not fit a
commercial Slate beta. Users can still import their own compatible local files;
Slate does not relicense them.
