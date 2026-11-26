# Sonook（听澜）技术路线图（ROADMAP）

> 项目名称：**Sonook（听澜）** · Swift Package：`Sonook` · CLI：`sonook`  
> 架构基线：[ARCHITECTURE.md](ARCHITECTURE.md)  
> 开发与验证：[贡献指南](CONTRIBUTING.md)
> 说明：本文件只定义阶段目标、验证实验与门禁条件（Gate），不预设具体排期。

---

## 阶段总览与门禁（Gates）

| 阶段 | 状态 | 核心交付 | 进入下一阶段的 Gate |
|---|---|---|---|
| **P0 技术验证** | 已通过 | 原生 Swift MLX（LLM / TTS / ASR）最小多角色闭环、5 款 TTS 横评（拍板 `9B + VoiceDesign 定妆 + VoxCPM2 48 kHz 锁定`）、人物声音档案持久化、交替加载释放内存基准、构建与许可审计、[ADR-0001](docs/adr/0001-p0-native-mlx-runtime.md) | 1. 原生 Swift 独立跑通 LLM / TTS / ASR 三个后端并记录兜底路径；<br>2. 用真实中文小说章节生成可试听多角色音频，原文 UTF-8 偏移 100% 可回溯；<br>3. LLM 产出并持久化版本化人物声音档案（JSON + Markdown）并保持角色一致性；<br>4. 测得 M5 Max 64GB 分阶段交替加载/释放峰值内存、RTF、CER 基线并输出 ADR |
| **P1 引擎基建** | 已通过 | `AudioCore`（含可选背景音隔离指纹与角色成长声线演进契约）、`StorageKit`（系统 SQLite3 WAL + POSIX 原子资产与孤立回收）、`ModelRuntime`（租约与内存调度、段间清缓存）、`WorkflowKit`（持久化 DAG 与 fencing 租约）、`EngineSDK`、`SonookCLI`、[ADR-0002](docs/adr/0002-p1-storage-workflow-runtime.md) | Fake Provider 与真实模型任务均可持久化执行、取消（检查点安全）、断点恢复与诊断（46 项测试 + 真机跨进程取消续跑验收通过） |
| **P2 有声书 MVP** | 已通过 | 11 Target 零 MLX 领域分层：`StorageKit`（`v1→v2` 迁移）、`ContentKit`（严格 GB18030/UTF-8/UTF-16 + 纯 Swift 安全 EPUB）、`NarrativeKit`（确定性 `temperature=0.0, seed=42` 9B 对白归属 + 规则后校验 + `VoiceDeliveryStage`）、`DirectorKit`（全章原文保真切分与全书唯一 `segmentID`）、`SpeechKit`（原生 ICU 声调拼音专词容错 ASR 质检 + 单段隔离重生成）、`AudioRenderKit`（原生 `AVAssetWriter` `tx3g` 中文 M4B 章节导出与回读 + 可选背景音自动闪避混音）、`EngineSDK`/`SonookCLI` 完整命令与 `~/Sonook` 本地目录命名规范、[ADR-0003](docs/adr/0003-p2-audiobook-mvp.md) | 82 项单元测试与架构红线全绿；M5 Max 真机完成真实多章中文有声书端到端生产、中途取消跨进程续跑（0 重复推理）、单段局部重生成（其余 32 段哈希零变动）与原生 M4B 导出（Apple `AVURLAsset` 中文章节回读通过） |
| **P3 长篇可靠性** | 已通过 | `StorageKit`（`v2→v3` 迁移与 SQL 层防剧透 `chapter_memories`）、`NarrativeKit`（`ChapterMemoryTracker` 有界防剧透角色窗口 + 容错阶段解码）、`SpeechKit`（后置分批自动换 Seed 修复策略 + 最佳候选择优 + 旁白 F0 音高漂移质检守卫 + `CacheInvalidationPlanner` 精准缓存失效）、`EngineSDK`/`SonookCLI`（逐章增量分析落库、Stage 4 自动修复 DAG、`review list\|retry\|approve-all\|reassign`、`cache plan`、`memory list`、POSIX `--json` stdout 净输出隔离）、`WorkflowKitTests` 故障注入与百章压测、[ADR-0004](docs/adr/0004-p3-long-form-reliability.md) | 99 项单元测试（108 用例）全绿，含真实 `SIGKILL` 租约抢占、同字节损坏检测与 100 章 / 1,500 段 2.07s 压测；M5 Max 5 连续章节（97 段，11 分 49 秒 `.m4b`）完成真机 GPU 中途 `kill -9` 强杀续跑（跳过全部 8 个前序检查点）、自动换 Seed 修复错读、`review reassign` 单段精准失效与 100% 纯净 `--json` 管道验收 |
| **P4 通用音频** | 已通过 | `AudioCore`（通用音频/音景/`SFXProvider`/授权改编/知识库契约）、`StorageKit`（`v3→v4` 迁移与 FTS5/CJK 混合检索）、`KnowledgeKit`（Markdown 分块入库、引用校验与共享管线私人播客规划）、`NarrativeKit`（9B 反幻觉剧情音景规划）、`DirectorKit`（显式授权广播剧改编与字节溯源）、`AudioRenderKit`（多轨交叉淡化+闪避+点音效+`-1 dBTP` 混音、CC0/PD 音效库注册表与隔离式 `SubprocessSFXProvider` 缓存桥接）、`EngineSDK`/`SonookCLI`（`soundscape`/`drama`/`podcast`/`export --soundscape`）、[ADR-0005](docs/adr/0005-p4-universal-audio-and-soundscapes.md) | 138 项单元测试 + CLI 集成测试全绿；M5 Max 真机完成三模态共享工作流验收（5 章真实小说 9B 剧情音景与 Public Domain 自然录音多轨 M4B 导出且干声零破坏、双人私人播客 `6/6 verified` 导出、显式授权广播剧 `11/11 verified` 多轨混音导出与未授权拦截） |
| **P5 服务与协同** | 已通过 | `AudioCore`（`.audiopack`/配对认证/离线同步/防剧透上下文契约）、`StorageKit`（`v4→v5` 迁移、原子配对消费与幂等事件写入）、`DistributionKit`（`.audiopack` 原子打包/安全校验与脱敏、`PlaybackSyncEngine` 去重+回退保护+按 `segmentID` 跨版本进度迁移）、`KnowledgeKit`（`SpoilerSafeContextResolver` 双层防剧透与独立交互锚点）、`EngineServer`（零依赖原生 `127.0.0.1` HTTP/1.1 + SSE、配对与可撤销最小权限令牌、`Range` 206 分章续传）、`EngineSDK`/`SonookCLI`（`publish`/`pack`/`releases`/`sync`/`context`/`server`/`serve`）、[ADR-0006](docs/adr/0006-p5-server-distribution-and-sync.md) | 175 项单元测试（11 目标）+ 实时回环客户端 8 项联调全绿；M5 Max 真机完成 5 章 11.15 MB 音景 `.audiopack` 发布校验（零音色样本/私密路径泄露）与真 `Qwen3.5-9B` 第 2 章防剧透拦截（自动扣留 1,029 未来章节并拦截参数记忆剧透）及显式解锁验收 |
| **P6 Engine 1.0** | 1.0.0 发布文档与开放契约就绪 | 安装与卸载契约、SemVer、Apache-2.0、中英入门指南、[开放包规范](docs/specs/audiopack-v1.md)、[许可审计](docs/THIRD_PARTY_LICENSES.md)与[安全指南](SECURITY.md) | 整合版独立安装与整书制作、卸载保留用户数据、全树隐私扫描通过后可发布。见 [ADR-0007](docs/adr/0007-p6-engine-1-0-release.md)。 |
| **P7 App 产品设计** | 后续独立开展 | Mac 生产端 / iPhone 收听端 / CarPlay 驾驶延伸的独立 PRD、交互原型与商业策略 | 引擎稳定且产品与技术评审完成后启动 |

---

## P0 技术验证详细拆解（已完成归档）

### P0.1 仓库与工程护栏
- 本地 Git 初始化、隐私与大文件 `.gitignore` 隔离（外部小说原文、音频输出、本地权重绝不入仓）。
- 首提即具备自动化检查（`scripts/check.sh` + `.github/workflows/ci.yml`）：架构红线守卫检查（`AudioCore` 禁引 UI 与具体模型框架）+ 纯逻辑单元测试 + Fake Provider 契约测试。
- 仅创建 P0 所需最小 target（`AudioCore`、`P0Runtime`、`SonookCLI`），不预建 P1–P6 空壳模块。

### P0.2 核心契约与双轨测试语料
- **`AudioCore` 最小跨平台契约**（不依赖 macOS 专属框架、无第三方模型依赖）：
  - `SourceNormalizer`：处理 UTF-8 / UTF-16 LE/BE / BOM 与 CRLF → LF，产出不可变规范化 UTF-8 原文及内容哈希。
  - `SourceSpan`：严格使用 UTF-8 字节半开区间 `[start, endExclusive)`，杜绝 `String.Index` / UTF-16 / UTF-8 混用。
  - `CharacterVoiceCard` & `CharacterVoiceCatalog`：LLM 基于文本生成的版本化人物画像与声音风格档案（同时支持机器消费的 JSON 与人类可读可手改的 Markdown 双向/持久化存储），支持别名归一化与跨片段/跨章节声线锁定。
  - `ScriptDocument` / `ScriptSegment`：带 `schemaVersion` 的原文保真剧本契约，支持 `Pending / Synthesized / Verified / NeedsReview / Failed`。
  - `LLMProvider` / `TTSProvider` / `ASRProvider`：最小统一协议，显式能力声明与不支持参数降级/拒绝记录，含 `load()` / `unload()` 生命周期钩子。
  - 校验与质检原语：`SourceCoverageValidator`（100% 原文覆盖校验）、`ChineseCERCalculator`（可审计文本规范化 + CER + 漏读/重复检测）、`AudioIntegrityChecker`（时长/静音/削波检测与 `NeedsReview` 判定）。
- **双轨测试语料**：
  - 公开单测 Fixtures（`Tests/AudioCoreTests/Fixtures/p0-unit-sample.txt`）：原创无版权中文多角色样例，保障开源 CI 脱离本机私有文件也可独立运行。
  - 本机真机验证语料：通过外部只读路径参数读取真实中文小说章节，产物输出到 `.gitignore` 忽略目录。

### P0.3 上游 Swift MLX 构建与依赖审计
- 验证 `ml-explore/mlx-swift-lm` 与 `Neywa-Labs/mlx-audio-swift` 在 Swift 6.x / Xcode 下的 SPM 解析兼容性与许可证清单。
- 实测 `swift build` 与 `xcodebuild` 的 Metal shader（`default.metallib`）编译和 CLI 运行路径，固化可复现构建脚本。
- 若两个 Swift 包存在底层依赖冲突，验证隔离进程 Provider 兜底边界，确保 `AudioCore` 契约不受污染。

### P0.4 三模型独立验证与最小多角色闭环
1. **LLM（主线 `Qwen3.5-9B-4bit`）**：通读真实小说章节 → 产出并持久化版本化人物声音档案（JSON + Markdown）→ 输出 100% 原文覆盖的结构化对白与情绪指令 JSON。
2. **TTS（`Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16`）**：读取人物声音档案绑定对应说话人与语气，分片合成多角色音频；使用原生 `AVFoundation` 拼接并导出 WAV/M4A 试听成品；统计分段与整体 RTF（区分含/不含加载耗时）。
3. **ASR（`Qwen3-ASR-1.7B`）**：回听合成音频并计算中文 CER；构造错误注入样本（漏句/错读/静音）验证质检拦截与 `NeedsReview`。

### P0.5 分阶段交替加载释放基准 & 可选 27B 零下载对照
- 按「加载 LLM → 剧本与人物档案 → 释放 LLM & 清缓存 → 加载 TTS → 分片合成 → 释放 TTS → 加载 ASR → 批量质检 → 释放 ASR → 失败片段局部重生成」跑通完整闭环。
- 采样记录：加载耗时、吞吐、进程物理内存峰值（`phys_footprint` / RSS）、MLX GPU 活跃/峰值/缓存内存、释放后常驻内存与系统热压力。
- 若 9B 全链路顺利收官且架构兼容，就地零下载对比测试本地 27B MLX 模型（`Qwen3.8-27B`）的内存峰值与对白归属质量。

### P0.6 沉淀与门禁交付
- 输出 `docs/adr/0001-p0-native-mlx-runtime.md`（架构与运行时决策记录）。
- 输出 `Benchmarks/p0-baseline.md`（脱敏基准报告与本地试听路径）。
- 依据实测结果更新 [ARCHITECTURE.md](ARCHITECTURE.md) 中的待验证事项状态，完成 P0 门禁评审后再开启 P1。
