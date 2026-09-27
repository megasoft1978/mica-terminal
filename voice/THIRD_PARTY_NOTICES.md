# Third-party notices

## FluidAudio

Mica uses [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.4 for local audio transcription. FluidAudio is licensed under Apache License 2.0. The license text is included as `LICENSE-FluidAudio.txt`; its bundled third-party notices are in `ThirdPartyLicenses/`.

## Parakeet Ultra speech model

Mica downloads FluidInference's Core ML conversion of [Moondream Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) the first time Dictation is used. Parakeet Ultra is © Moondream, is based on NVIDIA Parakeet TDT 0.6B v3, and is licensed under [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/legalcode). The model supports English, Italian, and 23 other languages. Mica makes no changes to the model weights and does not bundle them in the app.

The Core ML model is provided by [FluidInference](https://huggingface.co/FluidInference/parakeet-ultra-coreml). Model attribution: “Parakeet Ultra by Moondream, based on Parakeet TDT by NVIDIA, distributed through FluidInference.” The model's CC BY 4.0 license permits commercial use and redistribution with attribution and license notice; see the linked license for its full terms.

## Apple frameworks

Mica uses Apple's AVFoundation and Core ML frameworks under Apple's platform terms. It inserts the local speech recognizer's transcript directly and does not run a second language model for cleanup.
