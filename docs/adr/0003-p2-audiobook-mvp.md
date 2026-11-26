# ADR-0003：P2 有声书 MVP（多格式安全导入、确定性 9B 叙事、专词声调质检、角色成长演绎与原生 M4B/可选背景音渲染）

- **状态**：已接受（P2 自动化单测 + M5 Max 真机多章端到端门禁验收通过）
- **日期**：2026-11-26
- **影响范围**：`Package.swift`、`Sources/AudioCore/`、`Sources/StorageKit/`、`Sources/ContentKit/`、`Sources/NarrativeKit/`、`Sources/DirectorKit/`、`Sources/SpeechKit/`、`Sources/AudioRenderKit/`、`Sources/EngineSDK/`、`Sources/SonookCLI/`、`scripts/check.sh`、`ARCHITECTURE.md`、`ROADMAP.md`
- **前置 ADR**：[ADR-0001](0001-p0-native-mlx-runtime.md) · [ADR-0002](0002-p1-storage-workflow-runtime.md)

---

## 1. 背景

P1 引擎基建完成后，Sonook（听澜）已具备系统 SQLite3 持久化、内容寻址原子资产、带 fencing token 的持久化 DAG 以及 Apple Silicon 资源租约调度能力。进入 P2 有声书 MVP，需要将「单章实验闭环」推进为「完整的多章中文多人有声书生产管线」，同时兑现两项核心产品体验目标：

1. **角色成长声线连贯演进**：角色核心音色锚定在不可变定妆参考音（`VoiceTimbreAnchor`）上，随着跨章剧情推进由 `NarrativeKit` 抽取按章生效的演绎基线（`VoiceDeliveryStage`），兼顾长篇音色连贯与语气/沉稳度演进；
2. **可选背景音低音量混音（默认关闭）**：严格隔离在 ASR 干声质检之后的渲染导出层，仅计入渲染指纹，不污染干声 TTS 与 ASR，切换背景音零重复推理。

---

## 2. 架构与关键技术决策

### 决策 1：新增 5 个零 MLX 领域 Kit（11 Target 严格单向无环分层）

- 新增 `ContentKit`、`NarrativeKit`、`DirectorKit`、`SpeechKit`、`AudioRenderKit` 5 个独立 Swift Package target，与既有的 `StorageKit`、`WorkflowKit` 共同构成 **7 个零 MLX、零 UI 依赖的领域与基础设施库**：
  - `AudioCore`（仅 `Foundation` + `CryptoKit`，新增书目 `SourceDocumentRecord` / `ChapterRecord`、人工审批 `SegmentApprovalRecord`、专词质检 `SegmentQualityAudit` 与 `ChapterMarker` / `BookExportMetadata`）；
  - `ModelRuntime` 仍是全仓唯一允许 `import MLX*` 的 target；
  - `EngineSDK` 统一组合全部 10 个库提供完整 P2 Application Services；`SonookCLI` 为纯薄壳入口，零业务逻辑重复；
  - `scripts/check.sh` 扩展至全部 8 个无 GPU 测试目标（沙箱离线秒级运行）+ 架构红线与隐私守卫。

### 决策 2：`StorageKit` 顺序事务迁移 `v1 → v2`（保留历史数据）

- `SQLiteDatabase` 将原固定版本检查升级为顺序写事务迁移（`empty → v1 → v2`、`v1 → v2`、显式拒绝未知未来版本）。
- `schemaV2` 新增 `source_documents`、`chapters`、`segment_approvals` 三张表及索引，完整实现 `SourceCatalogStoreProtocol`，保障所有 P1 存量工作区无损平滑升级。

### 决策 3：零第三方依赖的安全导入（严格 GB18030/UTF-8/UTF-16 + 纯 Swift 安全 EPUB）

- **严格编码探测**：支持 `UTF-8`（含/不含 BOM）、`UTF-16LE/BE`（含/不含 BOM）与基于 `CoreFoundation` 的 `GB18030`（含 4 字节扩展汉字），执行字节合法性与无损往返校验，禁止静默替换为 `U+FFFD`；编码歧义时显式报 `ambiguousEncoding` 引导用户传 `--encoding`。
- **纯 Swift 安全 EPUB**：仅依赖 Apple 系统 `Compression`（`COMPRESSION_ZLIB` raw deflate）+ IEEE CRC32 + `Foundation.XMLParser`（禁用外部实体并预检拒收 `<!ENTITY`），零第三方 ZIP 依赖。解压前强制校验 ZIP 中央目录与 local header 一致性、防重叠加重叠记录、拒绝绝对路径 / `..` 穿越 / 符号链接 / 规范化重复路径 / DRM 加密，并在流式解压中实时限制单文件 `16 MiB`、总解压 `64 MiB`、条目数 `2000` 与膨胀比 `100×`。

### 决策 4：确定性 9B 叙事分析 + 机械规则后校验 + 全书唯一 `segmentID`

- **消除采样漂移**：`MLXLocalLLMProvider` 接入 `MLXRandom.seed`，`NarrativeKit` 全部 LLM 请求锁定 `temperature = 0.0`、`seed = 42`、`enable_thinking = false`，并采用带角色 `personaSummary` 的结构化 JSON CoT 提示词（`evidence` 先于 `speaker`）。
- **机械规则后校验（`DialogueAttributionValidator`）**：
  - 呼语排除铁律：直呼某人姓名/外号时排除其为说话人（2 人对话确定性纠偏，3 人及以上转 `needs_review`）；
  - 锁定 2 人连续对白交替校验：无旁白插断的 2 人连续对白中，对呼语引发的直接回应/反驳/道歉/拒绝链式纠偏，遇到旁白续说（如 `又道`）或第 3 人插入立即停止交替，不盲翻；
  - 角色成长阶段（`VoiceDeliveryStage`）须提供本章原文逐字引文才予采纳，且不推进基础声线 `revision`，避免失效历史章节缓存。
- **全章原文保真切分（`DirectorKit`）**：`maxCharacters = 0` 默认完整切分整章不截断，生成全书全局唯一 `segmentID`（`<chapterID>_seg_0001`）与相对整本书规范化 UTF-8 字节的绝对半开区间 `SourceSpan`，经 `SourceCoverageValidator` 100% 校验。

### 决策 5：基于原生 ICU 声调拼音的专词容错 ASR 质检与严格导出门禁

- **解决同音专词误报而不放水**：`SpeechKit` 使用 Apple 原生 `.mandarinToLatin` ICU 变换（零外库）做**带声调精确拼音比对**，仅对字符级对齐为严格 1-对-1 替换、且严格落在角色表唯一 `≥2` 字汉字名/别名内的**同调同音替换**记录 `ProperNounExemption` 豁免。
- **硬底线不放水**：异调替换、非人名错读、任意漏字（deletion）、增字/重复、音频静音/削波/截断永不豁免；每条质检产出完整可审计 `SegmentQualityAudit`（同时保留 `raw_cer`、`adjusted_cer` 与豁免明细）。
- **纯标点停顿与符号归一化**：纯标点/分隔行（如中文小说常见独立段落 `……`、`***`）由 `SpeechRequestBuilder.isNonVerbalPauseText` 识别为确定性 48 kHz 静音停顿 WAV（不浪费 TTS/ASR，且在开启环境音时自然露出背景音过渡）；`ChineseCERCalculator.normalize` 同步剥离波浪号等非朗读装饰符号（`~` / `～` / `♪`），消除无声符号引发的假 CER 漂移。
- **单段隔离重生成与正式导出门禁**：`SingleSegmentRegenerator` 仅重算目标片段 1 次 TTS + 1 次 ASR，新候选不合格绝不覆盖既有合格音频；`sonook export` 强制要求所选章节全部片段均为 `verified` 或经 `sonook segment approve` 显式审批，否则拒绝导出。

### 决策 6：原生 Apple `AVAssetWriter` `.m4b` 章节封装与可选背景音自动闪避混音

- **零 `ffmpeg` 原生 `.m4b`**：`AudioRenderKit` 使用 `AVAssetWriter` 输出 AAC 音轨并挂载禁用显示但关联为 `chapterList` 的 QuickTime `tx3g` UTF-8 文本轨。为彻底避免长章（>2 秒）下稀疏章节轨与连续音频轨触发 `AVAssetWriter` 多轨交织器死锁，双轨统一采用 Apple 官方拉取模型 `requestMediaDataWhenReady(on:)` 在同一串行队列独立拉取写入，支持中文章节标题与精确非整数时间戳，并内置 `M4BChapterReader` 通过 `AVURLAsset.loadChapterMetadataGroups` 自动回读校验。
- **可选背景音（默认关闭）**：`AmbientAudioMixer` 在干声母带拼装后执行，提供循环接缝交叉淡化、起止淡入淡出、基础增益（默认 `-24 dB`）与平滑人声包络闪避（默认 `-8 dB`，快速检测起落 + 平缓增益恢复），在停顿与章间自然浮现、开口时平滑退让，且与干声 WAV / ASR 完全隔离。

---

## 3. P2 门禁实测验收结果（Apple M5 Max · 64 GB · macOS 27.2 · Swift 6.4.2）

### 3.1 自动化测试与架构红线守卫（`./scripts/check.sh`）

- 全部 **8 个无 GPU 测试目标 78/78 全绿**（`AudioCoreTests` 28、`StorageKitTests` 9、`WorkflowKitTests` 12、`ContentKitTests` 8、`NarrativeKitTests` 5、`DirectorKitTests` 3、`SpeechKitTests` 9、`AudioRenderKitTests` 4），包含：
  - `SQLiteDatabase` `v1 → v2` 迁移及 P1 真实存量工作区无损升级实测（`schema_version: 1 → [1, 2]`，既有项目与任务记录完整保留）；
  - GB18030 / UTF-16LE / UTF-16BE / UTF-8 / Markdown / 纯 Swift 安全 EPUB 解压及恶意 `../escape.txt` 路径穿越拦截（`unsafeArchivePath`）；
  - 15 秒长章（8.0s + 6.5s @ 48 kHz）原生 `.m4b` `AVAssetWriter` 防死锁回归测试与 `AVURLAsset` 中文章节回读测试；
  - 纯标点停顿段（`……`）免调 TTS/ASR 及装饰波浪号（`~~`）CER 归一化回归测试。
- 架构红线守卫全绿：核心引擎零 UI 导入、`AudioCore` 零模型/存储框架导入、仅 `ModelRuntime` 导入 `MLX*`、隐私/版权路径守卫 0 命中。

### 3.2 M5 Max 真机多章端到端实测（真实中文长篇小说前两章，共 33 段）

| 验收项 | 实测结果 |
|---|---|
| **多格式安全导入** | 真实 UTF-16LE 长篇小说（`10,060,322` 字节，自动切分 `1,032` 章）、GB18030 TXT、Markdown、合法 EPUB 全通过；恶意 `../` EPUB 退出码 1 拒绝 |
| **9B 冷启动确定性** | 两次独立冷启动 OS 进程（`temperature=0.0, seed=42`）分析第 1 章，产出 20 段剧本与角色卡 **100% 字节一致**；第 1 章两位角色的 4 轮交替对白及后续应答全部准确；纯旁白批次自动跳过 LLM 归属调用 |
| **断点取消与跨进程续跑** | `sonook generate --chapters 1-2 --stop-after 6 --run` 完成 4 位角色定妆（`VoiceDesign`）+ 前 5 段 48 kHz 合成后安全取消（`doctor`: `missing=0, corrupted=0, orphans=0`）；新 OS 进程 `sonook job resume` 精准跳过前 **6** 个已完成节点（**0 次重复推理**），以 **RTF 0.21–0.23** 完成剩余 28 段 48 kHz 合成（含第 2 章独立 `……` 段自动生成 0.90s 确定性停顿）与全量 `Qwen3-ASR-1.7B` 质检，失败节点数 **0** |
| **实测模型峰值内存** | `qwen3.5-9b` **5,667 MiB** · `qwen3-vd` **10,915 MiB** · `voxcpm2-8bit` **9,238 MiB** · `qwen3-asr` **4,298 MiB**（分阶段交替卸载，64 GB 统一内存全程热状态 `nominal`） |
| **专词声调容错质检** | 33 段中共触发 **13 处** 精确同调专词豁免（分布在 10 个片段），拦截了 6 处本会被误判的假警报；同时准确拒绝豁免 2 处真实 1 声错读与 1 处未消解说话人归属标记，初筛 `30/33` 自动通过、`3` 段阻断并实测被 `sonook export` 门禁拒绝（退出码 1） |
| **单段隔离重生成** | 针对 1 声错读段 `ch_002_seg_0005` 执行 `sonook segment regenerate --seed 77`，29 秒内将 `adjCER` 从 `9.09%` 降至 **`0.00%`** 并自动替换（`swapped=true`, `status=verified`）；同时程序校验其余 **32 个片段的 WAV 资产 ID 100% 未变更**；另对 `ch_001_seg_0007` 验证了不合格不覆盖（`swapped=false`）与显式覆盖 + `sonook segment approve` 审批留痕后 `verify` 通过（`export_ready=true`, 退出码 0） |
| **双版本原生 M4B 导出与回读** | 零 `ffmpeg` 4 秒内完成两版 48 kHz AAC（128 kbps，总时长 **251.22s**）导出：<br>• 纯人声版（默认关闭环境音）：`3.86 MB`，`ambient_mixed=false`<br>• 微雨环境音版（`-24 dB` 增益 + `-8 dB` 人声闪避）：`3.94 MB`，`ambient_mixed=true`<br>两版 `render_fingerprint` 不同、全部 **33 段干声资产 SHA-256 100% 相同**（切换背景音 **0 次额外 TTS/ASR**）；`afinfo` 与 Apple `AVURLAsset` 均准确回读 2 个中文章节（`[0.00s +144.56s] 第0001章 棋局`、`[144.56s +106.66s] 第0002章 精神摧残`）；收尾 `sonook doctor` 报告 `missing=0, corrupted=0, orphans=0` |

---

## 4. 遗留与后续演进（移交 P3 长篇可靠性）

- **上游包标准输出降噪**：上游 `mlx-audio-swift` 模型加载期间会直接向 `stdout` 打印调试行；P3 在 `ModelRuntime` 或 CLI JSON 输出前需隔离/重定向底层 stdout，确保 `--json` 在含模型加载的命令上始终保持纯 JSON 可管道解析。
- **跨章人物长期记忆与全书级长时压测**：P2 已验证多章端到端管线与单段局部重生成；百章/百万字级长篇自动重试、跨章记忆检索、精准缓存失效与故障注入压测按路线图在 **P3 长篇可靠性** 推进。
