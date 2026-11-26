# Sonook（听澜）P0 实测基准报告

> 测试日期：2026-11-25  
> 测试设备：Apple M5 Max · 18 核 CPU · 64 GiB 统一内存 · macOS 27.2（Build 26B8119）  
> 工具链：Swift 6.4.2 · Xcode 27.2（27B52）· Metal Toolchain 27B47  
> 构建模式：`swift build -c release`（原生 Swift MLX，无 Python 运行时）  
> 说明：所有真实小说测试数据仅在本机只读引用外部文件，本报告严格脱敏，不包含外部作品全文。

---

## 1. P0 测试所用依赖与模型

发布版本的全部 SwiftPM 锁定项、SDK 与模型许可见[第三方许可清单](../docs/THIRD_PARTY_LICENSES.md)。

| 组件 / 模型 | 锁定版本 / 来源 | 许可证 | 用途 |
|---|---|---|---|
| `ml-explore/mlx-swift` | `0.33.0` | MIT | Apple Silicon GPU 数组与 Metal 内核 |
| `ml-explore/mlx-swift-lm` | `6759555f`（`traits: []`） | MIT | 原生 Swift LLM/VLM 推理（Qwen3.5/3.8） |
| `Neywa-Labs/mlx-audio-swift` | `c7755e25` | MIT | 原生 Swift Qwen3-TTS 与 Qwen3-ASR |
| `huggingface/swift-transformers` | `1.4.0` | Apache-2.0 | 本地 Tokenizer 加载 |
| `Qwen3.5-9B-4bit` | 本地 MLX 权重（5.6 GB） | Apache-2.0 | P0 主线 LLM（速度档） |
| `Qwen3.8-27B-local-affine4` | 本地授权 MLX 权重（~15.5 GB） | Apache-2.0 | P0 27B LLM 对照（精度档） |
| `Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16` | 本地 MLX 权重（4.2 GB） | Apache-2.0 | P0 多角色 TTS（9 预设音色 + 情绪指令） |
| `Qwen3-ASR-1.7B` | 本地 HF 缓存（3.6 GB） | Apache-2.0 | P0 ASR 回听与 CER 质检 |

---

## 2. 端到端多角色闭环实测（真实中文长篇小说第 1 章前段，773 字 / 2,267 UTF-8 字节 / 20 段）

主线配置：`Qwen3.5-9B-4bit` + `Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16` + `Qwen3-ASR-1.7B`

| 指标 | 实测结果 | 架构候选目标 / Gate 要求 | 结论 |
|---|---|---|---|
| 原文编码检测与规范化 | 自动识别 `UTF-16LE + CRLF` → 规范化 UTF-8 LF | 不可变原文 + UTF-8 半开区间 | 通过 |
| 原文结构覆盖率 | **100.00%**（20/20 段，0 缺口，0 重叠，0 未授权改写） | 100% | 通过 |
| 人物声音档案持久化 | 提取 5 个角色（含旁白），JSON + Markdown 无损往返 `true` | 版本化持久化、可人工编辑 | 通过 |
| 对白归属批量 JSON 解析率 | **100%**（20/20 段；第 4 章 31/31 段） | 结构校验通过 | 通过 |
| TTS 合成音频总时长 | **169.52 秒**（拼接停顿后成品 **175.47 秒**） | 完整可试听多角色成品 | 通过 |
| TTS 稳态 RTF（不含加载） | **0.306**（单段 0.29–0.37） | `≤ 1.0` | 远超目标（3.27× 实时） |
| TTS 含加载总 RTF | **0.308**（模型加载仅 0.24s） | 注明是否计入加载耗时 | 通过 |
| ASR 总回听耗时 | **5.67 秒**（处理 169.52s 音频，约 30× 实时；加载 0.58s） | 支持批量质检 | 通过 |
| ASR 加权中文 CER | **3.32%**（15 段 `passed`，其中 11 段为 **0.00%**；5 段 `needs_review`，0 段 `retryable_failure`） | V1.0 目标 `≤ 2%`（P0 建立基线） | 基线已立；误差主因已定位（见下文） |
| 原生音频导出 | `AVFoundation` 导出 24 kHz Mono WAV（16.8 MB）+ AAC 64 kbps M4A（1.41 MB）+ `timeline.json`，`afinfo` 校验通过 | 原生渲染导出 | 通过 |
| 系统热压力状态 | 全程 **`nominal`** | 记录热压力 | 通过 |

> **CER 误差分析（实测定位）**：20 段中有 11 段 CER 为 `0.00%`，主要误差集中在单段高语速口语对白（`seg_0007` CER 31.58%，因 `CustomVoice` 说话人 `Eric` 自动触发四川方言覆盖 + 重复感叹词导致普通话 ASR 识别偏差）。

---

## 3. 分阶段交替加载与内存释放曲线（9B 全链路）

按 `LLM → 卸载 → TTS → 卸载 → ASR → 卸载 → 局部重生成（TTS → 卸载 → ASR → 卸载）` 单进程实测：

| 阶段检查点 | 加载耗时 | MLX Active | MLX Cache | 阶段 MLX Peak | 进程 `phys_footprint` | 热状态 |
|---|---:|---:|---:|---:|---:|---|
| `baseline` | — | 0.0 MiB | 0.0 MiB | 0.0 MiB | 4.4 MiB | nominal |
| `llm_loaded`（Qwen3.5-9B-4bit） | 488 ms | 4,805.0 MiB | 0.0 MiB | 4,832.2 MiB | 5,673.7 MiB | nominal |
| `llm_done`（画像 + 归属） | — | 4,805.0 MiB | 260.8 MiB | 5,696.6 MiB | 5,427.2 MiB | nominal |
| `llm_unloaded` | — | **0.0 MiB** | **0.0 MiB** | 5,696.6 MiB | 5,056.3 MiB | nominal |
| `tts_loaded`（Qwen3-TTS-1.7B-bf16） | 239 ms | 4,306.5 MiB | 24.0 MiB | 4,330.5 MiB | 4,704.7 MiB | nominal |
| `tts_done`（20 段合成后） | — | 4,338.5 MiB | 778.8 MiB | **9,728.6 MiB** | **11,129.5 MiB** | nominal |
| `tts_unloaded` | — | **0.0 MiB** | **0.0 MiB** | 9,728.6 MiB | 6,987.1 MiB | nominal |
| `asr_loaded`（Qwen3-ASR-1.7B） | 583 ms | 3,893.2 MiB | 8.8 MiB | 3,893.2 MiB | 4,334.2 MiB | nominal |
| `asr_done`（20 段回听后） | — | 3,893.2 MiB | 0.6 MiB | 5,029.3 MiB | 4,388.6 MiB | nominal |
| `asr_unloaded` | — | **0.0 MiB** | **0.0 MiB** | 5,029.3 MiB | 3,958.7 MiB | nominal |
| `regen_final_unloaded` | — | **0.0 MiB** | **0.0 MiB** | 7,614.8 MiB | 3,878.3 MiB | nominal |

**关键结论**：
- 三个模型交替切换时，MLX Active 与 Cache 均稳定释放至 **`0.0 MiB`**，操作系统顺畅复用已释放页面，未出现三模型内存叠加（总物理峰值受控于 TTS 解码阶段的 **10.87 GiB**，远低于 64 GiB 硬件上限）。
- `Qwen3-TTS-1.7B-bf16` 权重仅 4.2 GB，运行期 `phys_footprint` 峰值达 **10.87 GiB**，印证了 P1 `ResourceManager` 必须按运行峰值而非磁盘体积做内存预算。

---

## 4. 9B vs 27B 零下载对照（同一第 1 章 773 字 / 20 段 / 7 段对白）

| 维度 | `Qwen3.5-9B-4bit` | `Qwen3.8-27B-affine4` |
|---|---|---|
| 模型加载耗时 | **488 ms** | 2,072 ms |
| 人物画像 + 声音档案耗时 | **10.46 s** | 38.78 s |
| 20 段对白归属耗时 | **10.41 s** | 73.84 s |
| MLX Active / Peak | 4.69 GiB / **5.56 GiB** | 14.09 GiB / **15.43 GiB** |
| 进程 `phys_footprint` 峰值 | **5.54 GiB** | **16.24 GiB** |
| 卸载后 MLX Active / Cache | **0.0 MiB / 0.0 MiB** | **0.0 MiB / 0.0 MiB** |
| 原文覆盖率 & JSON 解析率 | 100.00% / 20/20 | 100.00% / 20/20 |
| 多角色对白归属质量 | 出现 1 处跨角色串人（将第三方呼唤误归上一角色），且 2 位年轻男性共用同一声线 | **准确区分所有交替对白与第三人呼唤**，并为不同男角色合理错开声线 |

---

## 5. 可靠性与架构红线专项验证

1. **跨章人物声线锁定（第 1 章 → 第 4 章）**：第 4 章加载第 1 章持久化档案（`rev=2, cards=5`）后合并至 `rev=3, cards=8`；主角 `char_002` 的 `voice_design_prompt` 与 `provider_bindings` 保持 **100% 一致**，同时自动新增第 4 章新出场的 3 个角色卡片，Markdown 往返校验通过。
2. **局部重生成资产隔离**：仅重生成最高 CER 片段（`seg_0007`），其余 **19 个已验证音频文件 SHA-256 校验 100% 未被修改**；且因重生成结果未优于原片（47.37% vs 31.58%），保留较优版本并维持 `needs_review` 审核状态。
3. **能力契约与故障注入**：
   - 向 `MLXQwen3TTSProvider` 传入不支持参数 `voice_clone_ref`：`.strict` 模式显式抛 `unsupportedParameter("voice_clone_ref")`；`.degrade` 模式显式写入 `DegradationRecord`（1 条），零静默忽略。
   - 注入全静音 PCM 片段：质检返回 `retryable_failure([silent])`。
   - 注入漏句转录文本：质检返回 `needs_review([highCER, suspectedOmission])`。
4. **单元测试与契约测试**：`./scripts/check.sh` 架构红线守卫 + `AudioCoreTests` **25/25 全部通过**（`0.007s`）。

---

## 6. 本机试听产物位置（已 `.gitignore`，不入仓）

- **V1（`Qwen3.5-9B` + 原始旁白参数，175.5 秒）**：`Benchmarks/local-artifacts/p0-ch01-qwen35-9b/preview.m4a`
- **V2（`Qwen3.8-27B` 精准拆人 + 旁白空 instruct / `temp=0.35` / 固定 seed / 温和响度与 12ms 淡入淡出，RTF 0.302，173.3 秒纯语音）**：`Benchmarks/local-artifacts/p0-ch01-qwen38-27b-v2/preview.m4a`
- 无损 WAV：`Benchmarks/local-artifacts/p0-ch01-qwen38-27b-v2/preview.wav`
- 可手改人物声音档案 Markdown：`Benchmarks/local-artifacts/p0-ch01-qwen38-27b-v2/characters.voice-cards.md`
- 精确采样帧时间轴：`Benchmarks/local-artifacts/p0-ch01-qwen38-27b-v2/timeline.json`
- 完整机器指标 JSON：`Benchmarks/local-artifacts/p0-ch01-qwen38-27b-v2/benchmark-report.json`

---

## 7. 多 TTS 原生 Swift MLX 横评（统一 `Qwen3.5-9B-4bit` 拆本，6 组串行实测）

为解决 `CustomVoice` 预设池受限及方言绑定问题，使用同一份由 **`Qwen3.5-9B-4bit`（Structured-CoT + 呼语排除 + 性别守卫）** 生成的第 1 章前段剧本（773 字 / 20 段 / 7 段对白 / 4 个去重角色，100% 角色与交替对白准确、100% 原文覆盖），通过 `sonook p0-tts-bench` 在 M5 Max 上串行实测 5 款原生 Swift MLX TTS 模型（共 6 组模式），统一使用 `Qwen3-ASR-1.7B` 质检与相同后处理导出 M4A：

| 方案（`engine`） | 采样率 | 许可证 | 加载耗时 | 合成音频 | 稳态 RTF | 加权 CER（旁白 / 对白） | 质检通过 | MLX Peak | 进程 `phys_footprint` Peak | 卸载后 MLX Active |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **`voxcpm2-locked`（推荐主线）** | **48 kHz** | **Apache-2.0** | **356 ms** | 137.4 s | **0.219** | **3.00%**（1.93% / 5.77%） | **16/20**（0 失败） | **7.46 GiB** | **9.50 GiB**（段间清缓存后） | 0.0 MiB |
| `qwen3-voice-design`（推荐定妆） | 24 kHz | Apache-2.0 | 1,011 ms | 156.2 s | 0.368 | 3.48%（2.06% / 6.94%） | 16/20（0 失败） | 8.84 GiB | 15.60 GiB | 0.0 MiB |
| `qwen3-custom-voice`（基线） | 24 kHz | Apache-2.0 | 478 ms | 174.3 s | 0.302 | 3.32%（2.06% / 7.12%） | 15/20（0 失败） | 9.63 GiB | 17.29 GiB | 0.0 MiB |
| `voxcpm2-design`（纯文本捏声） | 48 kHz | Apache-2.0 | 358 ms | 134.4 s | 0.328 | 3.63%（4.17% / 5.77%） | 14/20（0 失败） | 7.60 GiB | 49.51 GiB（修前未清缓存） | 0.0 MiB |
| `fish-s2-pro`（8-bit 5B 标杆） | 44.1 kHz | Research（非商用） | 783 ms | 148.7 s | 1.927 | 3.32%（2.06% / 6.86%） | 16/20（0 失败） | 13.25 GiB | 49.58 GiB（修前未清缓存） | 0.0 MiB |
| `indextts-1.5`（参考音克隆） | 24 kHz | IndexTTS License | 182 ms | 196.6 s | 0.414 | 11.06%（14.27% / 14.39%） | 11/20（1 失败） | 8.91 GiB | 49.45 GiB（修前未清缓存） | 0.0 MiB |

### 关键实测发现

1. **9B 剧本拆分达到 100% 准确（速度与精度兼得）**：在提示词中加入「结构化 JSON 推理字段（`coreference_notes` / 先 `evidence` 后 `speaker`）」「呼语排除铁律」「前后各 2 段上下文」以及代码级性别守卫后，`Qwen3.5-9B-4bit` 在同一第 1 章 773 字测试中实现 **4/4 角色正确合并去重 + 7/7 交替对白与第三者呼唤全对**，且无需依赖高延迟的 27B 模型（MLX 活跃仅 4.69 GiB）。
2. **`Qwen3-TTS-VoiceDesign` 定妆 + `VoxCPM2-8bit` 48 kHz 锁定合成是最优组合**：
   - `qwen3-voice-design` 直接按 LLM 产出的中文 `voice_design_prompt` 为 4 位角色各生成 4.8–9.0 秒干净的标准普通话定妆参考音（Audition Clips），彻底摆脱 9 音色和方言绑定。
   - `voxcpm2-locked` 吃进定妆参考音后以 **48 kHz 原生采样率** 合成全章，同时创下 **全场最快（RTF 0.219，4.57× 实时）**、**全场最低加权 CER（3.00%，旁白 1.93%）**、**全场最低显存峰值（MLX 7.46 GiB / 物理 9.50 GiB）**，且为 **Apache-2.0** 可商用协议。
   - 对比 `voxcpm2-design`（3.63%，14/20）与 `voxcpm2-locked`（3.00%，16/20），实证「定妆参考音锁定」比「每句重新文本捏声」既更稳也更准。
3. **ASR 专有名词同音误报定位**：`voxcpm2-locked`、`qwen3-voice-design`、`fish-s2-pro` 三者未通过的 4 段完全重合（`seg_0007/0015/0016/0020`），均包含人名专词被普通话 ASR 转写成同音词，其余 16/16 段全部无误通过；P2/P3 应在 ASR 质检中引入角色名/专词热词表或拼音等价容错。
4. **`Fish Audio S2-Pro` 与 `IndexTTS-1.5` 边界实测**：
   - `fish-s2-pro`（5B Dual-AR 8bit）精度与稳定性与第一梯队齐平（CER 3.32%，16/20），但 **RTF 1.927 慢于实时（比 VoxCPM2 慢 8.8 倍）** 且为非商用协议，适合作为高端听感参照而非默认主引擎。
   - `indextts-1.5` 在 `mlx-audio-swift` 中出现长句 EOS 停不下来（`seg_0013` 跑满 800 mel tokens 达 33.6s，CER 83.7%）及段内静音失败（`seg_0016` 24.5s，`internalSilence`），不适合作为当前主力。
5. **关键内存坑与修复验收（段间清 MLX 缓存）**：实测发现 `VoxCPM2Model`、`FishSpeechModel`、`IndexTTSModel` 在单句 `generate()` 结束时不会自动释放 MLX Metal 缓存池，导致 20 段连跑期间进程 `phys_footprint` 被缓存撑至 **49.5 GiB**（尽管实际活跃显存仅 1.4–6.7 GiB）。在各 Provider 的 `synthesizeAccepted()` 末尾加入 `MemoryProbe.clearMLXCache()` 后复测 `voxcpm2-locked`，进程物理峰值直降 **81%（49.51 GiB → 9.50 GiB）**，且因消除显存池碎片，稳态 RTF 反而再提速 **24%（0.289 → 0.219）**。

### 本次 6 组横评本机试听路径（已 `.gitignore`，不入仓）

- 统一 9B 剧本与声线卡：`Benchmarks/local-artifacts/p0-tts-shootout-9b/00-llm-9b-script/`
- 4 位角色定妆参考音：`Benchmarks/local-artifacts/p0-tts-shootout-9b/auditions/`
- 6 组完整 M4A 成品：
  - `Benchmarks/local-artifacts/p0-tts-shootout-9b/04-voxcpm2-locked/preview.m4a`（48 kHz，推荐首选）
  - `Benchmarks/local-artifacts/p0-tts-shootout-9b/01-qwen3-voice-design/preview.m4a`（24 kHz）
  - `Benchmarks/local-artifacts/p0-tts-shootout-9b/05-fish-s2-pro/preview.m4a`（44.1 kHz）
  - `Benchmarks/local-artifacts/p0-tts-shootout-9b/03-voxcpm2-design/preview.m4a`（48 kHz）
  - `Benchmarks/local-artifacts/p0-tts-shootout-9b/02-qwen3-custom-voice/preview.m4a`（24 kHz，基线）
  - `Benchmarks/local-artifacts/p0-tts-shootout-9b/06-indextts-1.5/preview.m4a`（24 kHz）
