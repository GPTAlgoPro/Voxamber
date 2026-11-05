# Native model selection and evidence

Evidence checked 2026-11-05. Device declarations below belong to upstream publishers; they are not our measurements. Runtime and acceptance receipts are recorded separately.

## Product decision constraints

The app performs general Chinese→3D composition through `CreationCore.SceneSpec` and deterministic native geometry. `BuildingSpec` is an additional architecture example and the initial parameter-accuracy benchmark; it does not define the product's scope. The user subsequently allowed 12 GB+ iPhones, Qwen or MiniCPM, and task-appropriate INT4 quantization, then imposed a hard 8B model ceiling. The shipped app must contain no Python or JavaScript interpreter. Mac build/download helpers are outside the app bundle.

## Candidates

| Candidate | Evidence / practical footprint | Selection implication |
| --- | --- | --- |
| MiniCPM-V 4.7 35B-A3B LES | Official guide demonstrates iPhone 17 Pro Max and claims 13+ tokens/s with 3 GB runtime memory. App instructions recommend 12 GB device RAM. The mobile **split** asset is 15.504 GB for text and 16.624 GB with vision. | Historical research only; eliminated by the later explicit 8B ceiling and removed from the app catalogue. |
| MiniCPM-V 4.7 1B Q4_K_M | Official iPhone 17 Pro Max recording; app guide recommends ≥4 GB RAM. Validated mobile LLM is 672,003,584 bytes, optional f16 projector 1,108,746,816 bytes. | Fast baseline. No claim that latest 1B beats every previous larger model on every task. |
| MiniCPM-V 4.0 4.1B Q4_K_M | Official guide gives iPhone 16 Pro Max <2 s first token and >17 tokens/s; LLM 2.190 GB + projector 0.959 GB. | Older but genuinely mobile-demonstrated candidate. |
| MiniCPM-V 4.5 / MiniCPM-o 4.5 | V 4.5 official mobile example is iPad M4. o 4.5 guide lists 10 GB GGUF GPU memory and Mac ≥16 GB for half-duplex / ≥24 GB for full-duplex. | Does not establish smooth 8/12 GB iPhone full-duplex inference. |
| Qwen3.5 4B MLX INT4 | Official MLX Swift implementation supports `qwen3_5` and `qwen3_5_text`. Fixed community conversion is 3.061 GB with vision; text-only loader discards vision weights. | Better download and native MLX fit for the product; must pass Chinese parameter accuracy and device tests before selection. |
| Qwen3-4B-Instruct-2507 MLX INT4 | Mature Qwen3 architecture, non-thinking instruct, 2.279 GB snapshot. | Alternate if Qwen3.5 mobile performance or output accuracy is inferior. |
| Qwen3.5 9B / Qwen3.8 27B | 9B community INT4 snapshot is 5.977 GB before runtime state. A fresh official-org API enumeration found Qwen3.8's smallest official model is 27B. | Excluded by the hard 8B ceiling. |

Sources:

- [MiniCPM-V 4.7 model guide and unedited phone recordings](https://github.com/OpenBMB/MiniCPM-V/blob/main/docs/minicpm_v4dot7_en.md)
- [Official MiniCPM native apps: hardware recommendations and mobile split explanation](https://github.com/OpenBMB/MiniCPM-V-Apps/blob/d0dd7a6074b950081d6303977efb646f2f85bb5b/README.md)
- [MiniCPM-V 4.0 iPhone latency and throughput declaration](https://github.com/OpenBMB/MiniCPM-V/blob/main/docs/minicpm_v4_en.md)
- [MiniCPM-o 4.5 deployment limits](https://github.com/OpenBMB/MiniCPM-V/blob/main/docs/minicpm_o4dot5_en.md)
- [MLX Swift Qwen3.5 text factory registration](https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXLLM/LLMModelFactory.swift)
- [MLX Swift release](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3)
- [Qwen3.5 4B original weights and license](https://huggingface.co/Qwen/Qwen3.5-4B)
- [Qwen3.5 4B MLX snapshot](https://huggingface.co/mlx-community/Qwen3.5-4B-4bit/tree/0e7ffd5c629ef7719d4cbc04069232580bfa9d9c)
- [Qwen3 4B instruct alternative](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/tree/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b)
- [Official Qwen model catalogue](https://huggingface.co/Qwen)

## Fixed assets and source

All individual weight/configuration byte counts, SHA-256 digests and public revision URLs are in `Apple/Resources/ModelCatalog.json`. The app downloader must stream to a temporary file, hash incrementally, and promote only after both digest and byte count match. A projector is optional and is not a claim of implemented image support.

MiniCPM engine is `tc-mb/llama.cpp-omni` commit `e0eca9d8f57ac8f5a5ad6191a8007b93436c1e71`, pinned by official MiniCPM-V-Apps commit `d0dd7a6074b950081d6303977efb646f2f85bb5b`. This repository builds its own minimal static library using native C++ and embedded Metal kernels; it does not copy the demo's prompt logging or full UI. The generic JSON GBNF and engine are MIT licensed. Mobile split weights remain subject to original Apache-2.0 terms.

The historical 35B investigation established that mobile assets need `-les.gguf` plus matching expert shards; a monolithic desktop GGUF is not equivalent. It is not an app option under the final 8B ceiling and its full download was stopped. No DSpark performance claim is made.

MLX Swift package versions are fixed: `mlx-swift-lm 3.32.3`, `mlx-swift 0.32.3`, `swift-transformers 1.3.0`. A small native Swift tokenizer adapter loads the snapshot directly; it makes no network requests. Qwen inference creates a fresh direct-answer session for each request, with an 8192-token KV limit, greedy decoding and output limit. Returned JSON must still pass the separate strict SceneSpec or BuildingSpec decoder and geometric constraints.

The formal baseline is Qwen3.5 4B INT4; its general 3D quality is still unaccepted. Qwen3.8 is the latest Qwen series, but the official org's current complete enumeration contains only 27B, 180B Flash-Next and 2.4T-A95B, plus their FP8 variants. The independent `empero-ai/Qwen3.8-4B-Distill` is explicitly a Qwen3.5-4B student trained on teacher traces, not an official small Qwen3.8 base. See `qwen-latest-audit.json` for the current query and [the official Qwen3.8 release repository](https://github.com/QwenLM/Qwen3.8). The app must not label Qwen3.5 as the newest Qwen series.

## Validation boundaries and negative results

The six early architectural parameter cases passed on Qwen4B, but they do not establish general 3D planning capability. Subsequent chair/robot/lamp/whale/aircraft tests exposed wrong axes, overlapping facial parts, disconnected geometry, malformed JSON and invalid freeform topology. Native JSON or finite-mesh acceptance must not be called visual quality acceptance. Raw artifacts, per-model PNG views and the corresponding `*-plan-macos-benchmark.json` reports retain these failures.

Qwen3-8B INT4 was evaluated as an industry 8B-class development comparison, not silently substituted into the app. The original has 8,190,735,360 parameters. It did not improve the tested five-scene pipeline sufficiently. The isolated CCORE Three.js 4B fine-tune also failed direct native ScenePlan compliance in all five sampled cases; a tokenizer class alias was recorded only in its ignored experiment directory. Native schema-constrained generation improved JSON structure but still produced invalid or visually wrong geometry. None of these results establishes TestFlight quality readiness.

The initial engine used greedy sampling for reproducible parameter extraction. Official Qwen cards recommend non-greedy settings for open-ended generation, so separate fixed-seed recommended-sampling reports were also produced. The conclusions describe the tested configurations, not a universal ranking of the weights. No Python/JavaScript generated by any model was executed.

For the Qwen3.5 reload-memory issue, session clearing and compiled-trace invalidation alone were ineffective. Disabling graph trace/fusion with `MLX.compile(enable:false)` reduced three-cycle post-unload active allocations from hundreds of MB to approximately 4/8/12 KB. The formal engine retains native Metal execution and this fix. See `qwen4b-lifecycle-without-compile.json`.

Physical-device first-output hangs require separate diagnosis. The new diagnostic `generateJSONDirect` exposes tokenizer, fresh-cache, prefill submission and first-raw-token stages without recording prompts or generated content. The arm64 iOS26 release target compiled successfully. On the measured Mac, tiny input (27 tokens) reached its first raw token in 0.127 s; the current full ScenePrompt input (1031 tokens) in 1.116 s at prefill chunk 128. See `qwen4b-direct-stage-macos.json`. These numbers do not prove the iPhone path is working.

## Reproduce

On the Mac, outside the app:

```sh
python3 scripts/setup_minicpm.py --framework --macos
python3 scripts/setup_minicpm.py --models --model-id minicpm-v-4.7-1b-q4km
python3 scripts/setup_minicpm.py --models --model-id qwen3.5-4b-mlx-int4
swift build -c release --package-path Apple/Packages/QwenNative
Apple/Packages/QwenNative/.build/release/QwenBench \
  Apple/.build/Models/qwen3.5-4b-mlx-int4 \
  docs/qa/qwen4b-macos-benchmark.json
```

The same six creation/edit prompts run in `MiniCPMBench`. Each benchmark calls the actual engine, then the production strict decoder, then independently checks requested properties and preservation of unedited parameters. Mac results establish model behavior on that Mac, not iPhone responsiveness or memory safety. Phone acceptance additionally needs first-token time, total generation time, peak resident memory, cancellation/background release, and launch/download/offline checks.
