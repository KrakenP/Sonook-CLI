# ADR-0001：P0 原生 Swift MLX 运行时、构建链路与多角色验证结论

- **状态**：已接受（P0 实测验证通过）
- **日期**：2026-11-25
- **影响范围**：`Package.swift`、`Sources/AudioCore/`、`Sources/P0Runtime/`、`Sources/SonookCLI/`、`ARCHITECTURE.md`、`ROADMAP.md`
- **基准报告**：[Benchmarks/p0-baseline.md](../../Benchmarks/p0-baseline.md)

---

## 1. 背景

在进入 P1 引擎基建之前，[ARCHITECTURE.md](../../ARCHITECTURE.md) 要求通过 P0 技术验证回答以下高风险问题：

1. Apple Silicon 上能否用纯 Swift 原生同时跑通 LLM、TTS、ASR 三类本地模型，且上游 Swift MLX 包之间无版本冲突？
2. `swift build` 命令行构建能否正常编译 MLX Metal Shader（`default.metallib`），还是必须依赖 Xcode `.xcodeproj`？
3. LLM 人物画像与声音风格档案（Character Voice Card）持久化后，能否跨章锁死声线并与 100% 原文 UTF-8 偏移可追溯机制协同？
4. 分阶段「LLM → 释放 → TTS → 释放 → ASR → 局部重生成」交替执行时，GPU 显存与进程物理内存是否能真正回落？
5. 9B 与 27B 级本地量化 LLM、1.7B TTS 与 1.7B ASR 在真实中文长篇小说章节上的实际质量、速度（RTF / CER）与能力边界如何？

---

## 2. 实测结论与架构决策

### 决策 1：采用原生 Swift MLX 单仓双包集成，锁定可复现 commit

在 M5 Max（64 GB 统一内存，macOS 27.2，Xcode 27.2，Swift 6.4.2）上实测确认：

- `ml-explore/mlx-swift-lm`（锁定 commit `6759555f2bd8f18c242102d73d149efde9f2f2e0`，`traits: []` 关闭未使用的 `FoundationModelsIntegration`，**MIT 许可**）
- `Neywa-Labs/mlx-audio-swift`（锁定 commit `c7755e2504181a771941bb6f9f26ea79b3cdfce3`，**MIT 许可**）
- 共同解析至 `ml-explore/mlx-swift` `0.33.0`（**MIT 许可**）与 `huggingface/swift-transformers` `1.4.0`（**Apache-2.0 许可**），**单 `Package.swift` 零依赖冲突**。
- 因两个上游包各自在非必需或调试配置下包含 `.unsafeFlags`，采用 **exact `revision` 锁定**既解决 SPM 限制又保证构建可复现。
- **架构红线保持**：`AudioCore` 保持零第三方依赖、仅用 `Foundation` + `CryptoKit`（兼容 macOS 14+ / iOS 17+）；所有 MLX / AVFoundation 实现严格隔离在 `P0Runtime`（未来拆入 `ModelRuntime` / `AudioRenderKit`）。

### 决策 2：纯 `swift build` 原生编译 Metal Shader（前置安装 Apple Metal Toolchain）

- 实测发现 Xcode 27.2 默认未预装 Metal 编译器组件，首次编译报 `missing Metal Toolchain`。
- 执行 `xcodebuild -downloadComponent MetalToolchain` 安装 `Metal Toolchain 27B47` 后，**纯 `swift build` / `swift build -c release` 即可原生编译全部 MLX `.metal` shader** 并自动在可执行文件旁生成 `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`（冷构建 31.4s，增量构建 10–13s）。
- 结论：**无需为命令行/开源构建额外维护 `.xcodeproj` 包装工程**；在 `scripts/check.sh` 中将无依赖的 `AudioCore` 单元测试作为默认快检（`<1s`，可在无 GPU / 沙箱 CI 中运行），完整含 MLX Metal 的构建通过 `./scripts/check.sh --full` 触发。

### 决策 3：上游加载器采用只读符号链接暂存目录保护原始权重

- 实测发现 `mlx-audio-swift` 的 `Qwen3TTSModel.fromModelDirectory` 与 `Qwen3ASRModel.fromModelDirectory` 在缺少 `tokenizer.json` 时会自动在目标目录生成该文件。
- 决策：`P0Runtime` 加载本地权重前统一创建临时目录树，对原目录子目录递归建目录、对权重文件建符号链接，卸载时清理临时目录，确保用户本地模型仓库与 HuggingFace 缓存始终**只读无污染**。

### 决策 4：采用「确定性原文分段 + LLM 人物画像捏声档案 + 批量归属」混合策略

- 为同时满足 **100% 原文 UTF-8 字节半开区间覆盖率**与 **LLM 人物声音一致性**：
  1. 导入层先经 `SourceNormalizer` 自动识别编码（实测真实中文小说为无 BOM/带 BOM 的 `UTF-16LE + CRLF`），统一规范化为不可变 UTF-8 LF 原文并计算 SHA-256。
  2. 确定性分段器切分旁白与引号对白，锁定精确 UTF-8 半开 `SourceSpan`（`SourceCoverageValidator` 实测 100.00% 覆盖、0 缺口、0 重叠、0 未授权改写）。
  3. LLM 先通读章节生成带版本号的 `CharacterVoiceCatalog`，持久化为**结构化 JSON + 无损可手改 Markdown**（`characters.voice-cards.json` / `.md`），包含人物画像、别名、`voice_design_prompt` 与 Provider 声线绑定；跨章（第 1 章 → 第 4 章）实测确认已锁定角色（如主角 `char_002`）声线与 `voice_design_prompt` 100% 保持不变。
  4. LLM 按 10 段/批（附 2 段上文衔接上下文）输出结构化对白归属与导演情绪指令，解析成功率 100%（20/20 与 31/31）。

### 决策 5：9B 结构化推理拆本 +「VoiceDesign 定妆 + VoxCPM2 48 kHz 锁定」双段 TTS 主线

- **LLM 分档（实测对比与提示词迭代）**：
  - 经过加入「结构化 JSON 推理字段（`coreference_notes` / 先 `evidence` 后 `speaker`）」「呼语排除铁律」「前后各 2 段上下文」及代码级性别守卫后，**`Qwen3.5-9B-4bit`**（加载 0.30s，MLX 峰值 5.56 GiB）在第 1 章 773 字测试中已实现 **4/4 角色正确合并 + 7/7 交替对白全对**，大幅缩小了与 `Qwen3.8-27B-affine4`（MLX 峰值 15.43 GiB，耗时 112.6s）的精度差距。
  - 结论：P1/P2 支持 9B（默认速度与低内存档）与 27B（复杂长篇高精度档）按硬件内存档位切换，不硬编码单一 LLM。
- **多 TTS 原生 Swift MLX 横评（统一 9B 剧本，5 模型 6 模式实测）**：
  - **`VoxCPM2-8bit`（定妆参考音锁定 + 局部情绪控制，`voxcpm2-locked`）**：**48 kHz 原生采样率**、**Apache-2.0**、稳态 **RTF 0.219（4.57× 实时）**、加权 **CER 3.00%（旁白 1.93%）**、MLX 峰值仅 **7.46 GiB**（段间清缓存后 `phys_footprint` 峰值 **9.50 GiB**），综合速度、音质、显存、稳定性与商用协议全面领跑。
  - **`Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16`**（24 kHz，Apache-2.0，RTF 0.368，CER 3.48%）：天然适合按 LLM 人物声音卡片生成 5–9 秒「角色定妆参考音（Audition Clip）」，与 `VoxCPM2` 组成全开源 Apache-2.0 双段生产线（`VoiceDesign` 捏声定妆 → `VoxCPM2` 48 kHz 锁音色主合成）。
  - **`Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16`**（24 kHz，Apache-2.0，RTF 0.302，CER 3.32%）：稳定但受限于 9 预设与方言绑定（`Eric` 强绑四川话、`Dylan` 强绑北京话）。
  - **`Fish Audio S2-Pro 8bit`**（44.1 kHz，非商用研究协议，RTF 1.927，CER 3.32%）：表现力强但慢于实时且协议非商用，保留为可选外部/实验 Provider。
  - **`IndexTTS-1.5`**（24 kHz，RTF 0.414，CER 11.06%，11/20 通过）：在 `mlx-audio-swift` 实测中出现长句 EOS 失控与段内静音，暂不纳入默认主线。

### 决策 6：内存调度与原生音频编码实测约束

- **显存释放与段间清缓存铁律**：
  - 卸载阶段：释放模型对象时必须同时销毁持有容器引用的 `ChatSession` 再调用 `MLX.Memory.clearCache()`，卸载后所有 LLM / TTS / ASR 模型的 MLX Active 与 Cache 均稳定归零（`0.0 MiB`）。
  - 批量合成阶段：实测 `VoxCPM2` / `FishSpeech` / `IndexTTS` 不会在单句结束后自清 MLX 缓存池，连跑 20 段会将进程 `phys_footprint` 推至 ~49.5 GiB；在 Provider 单句合成后显式调用 `MLX.Memory.clearCache()` 后，`VoxCPM2-8bit` 物理峰值直降至 **9.50 GiB**，稳态 RTF 从 0.289 提速至 **0.219**。P1 `ModelRuntime` 必须将段间缓存回收与运行峰值预算固化为强制规范。
- **原生 M4A 编码约束**：Apple CoreAudio AAC 编码器在 24 kHz 单声道下不支持 `128 kbps`（报错 `kAudioConverterErr_PropertyNotSupported`），按采样率自适应码率（`≤24 kHz` 用 `64 kbps`，`44.1/48 kHz` 用 `128 kbps`）后，原生 `AVAudioFile` 均正常导出标准优化 M4A（全部 6 组产物已通过 `afinfo` 校验）。

---

## 3. 兜底路径（记录在案）

当前 LLM、TTS、ASR 三条链路均已在原生 Swift MLX 中跑通，**无需退回 Python 兜底**。若后续 P2/P4 引入尚未有原生 Swift MLX 移植的新模型（如特定声音克隆或小众声学模型），将继续通过 `AudioCore` 的 `LLMProvider` / `TTSProvider` / `ASRProvider` 协议以隔离本地子进程接入，不改变核心领域模型与工作流接口。
