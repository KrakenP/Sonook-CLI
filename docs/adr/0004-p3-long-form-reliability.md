# ADR-0004：P3 长篇可靠性（跨章防剧透记忆、后置自动换 Seed 修复、批量审核与精准缓存失效、CLI JSON 净输出隔离与故障注入压测）

- **状态**：已接受（99 项自动化测试 + 100 章 / 1,500 段故障注入压测 + M5 Max 5 连续章节真机强杀与自动修复验收全部通过）
- **日期**：2026-11-26
- **影响范围**：`Sources/AudioCore/`、`Sources/StorageKit/`、`Sources/NarrativeKit/`、`Sources/SpeechKit/`、`Sources/EngineSDK/`、`Sources/SonookCLI/`、`Tests/`、`ARCHITECTURE.md`、`ROADMAP.md`
- **前置 ADR**：[ADR-0001](0001-p0-native-mlx-runtime.md) · [ADR-0002](0002-p1-storage-workflow-runtime.md) · [ADR-0003](0003-p2-audiobook-mvp.md)

---

## 1. 背景

P2 有声书 MVP 打通了多格式导入、确定性 9B 拆本、48 kHz 多角色锁定合成、专词声调质检与原生 `.m4b` 导出。要将引擎推向百章乃至百万字级无人值守生产，必须解决五个核心可靠性问题：

1. **百人长篇上下文爆炸与剧透污染**：若每章将全书上百名角色全量塞入 9B prompt，会撑爆上下文并拉低对白归属精度；同时重跑或查询第 `N` 章时绝不能泄露第 `N+1` 章以后的信息；
2. **长篇瞬时 TTS 错读的人工维护成本**：3–8% 的偶发声调错读或吞字在双章可手动单段重生成，在百章（3,000+ 段）场景下必须自动分批修复且绝不来回频繁切换模型显存；
3. **长篇 `NeedsReview` 审核与改派效率**：人工需要一眼看清待审片段的原文、ASR 转写、CER、可播放 WAV 路径，并能批量重试、批量阈值审批或单段改派说话人且只失效该片段缓存；
4. **上游推理库 stdout 污染破坏 `--json` 自动化管道**：上游 `mlx-audio-swift` 加载模型时向 `stdout` 打印调试行，导致外部脚本 `sonook ... --json | jq` 报错；
5. **进程强杀（`SIGKILL`）、磁盘字节损坏与长时分析中途失败的韧性**：需要逐章落库、强杀后零损坏接管与可重复的自动化故障注入防线。

---

## 2. 架构与关键技术决策

### 决策 1：SQLite `v2 → v3` 顺序事务迁移与存储层防剧透边界

- `StorageKit` 将 `schemaVersion` 升级至 `3`，新增 `chapter_memories(project_id, chapter_id, chapter_number, document)` 表及 `(project_id, chapter_number ASC, chapter_id)` 索引，支持 `[] / [1] / [1, 2] / [2]` 无损平滑迁移到 `v3`，继续拒绝未知未来版本（如 `v99`）。
- 防剧透边界直接下沉到 SQL 查询层：`chapterMemoriesUpTo(projectID:maxChapterNumber:)` 严格执行 `WHERE project_id = ? AND chapter_number <= ?`，解码前即隔离未来章节。
- `EngineSDK.analyzeChapters` 改为**逐章增量落库**（每章分析完立即提交 `catalog`、`script` 与 `chapterMemory`），避免长篇中途异常丢失前序已分析章节；`ChapterProfiles` 对非确定性 LLM 的 `delivery_stage_changes` 字段实施别名容错解码（兼容 `character_id` / `character_name` 等键并安全跳过不完整条目）。

### 决策 2：有界防剧透人物窗口与跨章记忆（`ChapterMemoryTracker`）

- 分析第 `N` 章时，仅加载 `chapter_number < N` 的历史记忆，并按优先级构造有界角色窗口（默认上限 `maxRosterSize = 20`）：`char_narrator` → 本章原文点名/别名命中角色 → 最近 3 章发声角色 → 高频常驻主角 → 已锁定角色；即使全书达百人以上，每章 9B 提示词仍保持紧凑稳定。
- 同步向画像提取注入最近 3 章紧凑前情摘要与活跃人物状态（地点、关系、当前境遇），并在每章校验后的真实发声人基础上生成版本化 `ChapterMemoryRecord`（`schema_version = 1`）。

### 决策 3：Stage 4 后置分批自动换 Seed 修复（零模型抖动 + 最佳候选择优）

- `AudiobookMLXJobConfig` 新增向后兼容字段 `maxRepairRounds`（默认 `2`），DAG 在全部 `04_asr_*` 节点之后串联 `05_auto_repair_round_01..N`（依赖边 `requiresVerified: false`，确保 `needs_review` 节点也会触发后置修复）。
- **零模型抖动设计**：每轮修复仅卸载 ASR 一次、批量加载主 TTS 一次、仅对有可恢复 ASR/音频缺陷的片段使用确定性偏移种子（`seed + round * 37`）重合成、再批量加载 ASR 一次核验；若待修集合为空则 0 ms 跳过且不加载任何模型；纯说话人归属待审但 ASR 已通过的片段绝不浪费 TTS 算力。
- **资产保护与择优铁律（`AutoRepairCandidateEvaluator`）**：绝不覆盖已 `verified` 资产；绝不用破损/静音候选覆盖已有完整音频；仅在候选通过 QA 或 `adjustedCER` 严格下降时才替换；所有审核与质检视图按当前生效的 `wavAssetID` 精准关联审计报告，防止被拒候选的指标遮蔽现役音频。

### 决策 4：`NeedsReview` 批量审核流与精准缓存失效规划（`CacheInvalidationPlanner`）

- 新增 `sonook review list | retry | approve-all | reassign`、`sonook cache plan` 与 `sonook memory list` 命令，复用 `EngineSDK/ReviewServices.swift` 统一应用服务：
  - `review reassign` 修改单段说话人后自动清理归属标记、推进 `scriptRevision` 并仅将该段置为 `.pending`；
  - `cache plan` 基于 `synthesisFingerprint` + 磁盘 SHA-256 完整性提前报告可复用与需重算的精确清单（修改某角色第 `K` 章起的 `VoiceDeliveryStage` 仅失效该角色第 `K` 章及之后的片段，第 `1..<K` 章与其余角色 100% 命中缓存）。

### 决策 5：CLI `--json` 底层 POSIX `stdout` 净输出隔离（`JSONStdoutIsolator`）

- 在 `--json` 模式下，CLI 启动即通过 `dup(STDOUT_FILENO)` + `dup2(STDERR_FILENO, STDOUT_FILENO)` 将所有第三方 Swift `print(...)` 与底层 C `printf(...)` 输出统一导流到 `stderr`，最终结构化 JSON 直接写回保存的原始 stdout 描述符，彻底解决上游 `mlx-audio-swift` 调试日志污染 JSON 管道的问题。

---

## 3. P3 门禁实测验收结果（Apple M5 Max · 64 GB · macOS 27.2 · Swift 6.4.2）

### 3.1 自动化单元测试与故障注入压测（`./scripts/check.sh`）

- 全部 **8 个无 GPU 测试目标 99/99 项测试全绿**（展开参数化用例共 **108** 个），架构红线与隐私守卫零违规，关键压测与故障注入指标：
  - **存储迁移**：全新 / `v1` / `v2` 工作区均可无损升级到 `v3`，迁移中断事务回滚，未知 `v99` 显式拒绝；
  - **真实 `SIGKILL` 租约抢占**：旧 worker 被 `SIGKILL` 后租约过期，新 worker 以递增 `leaseGeneration` 接管并提交，旧租约延迟提交被 `leaseRejected` 拦截且不污染新资产（耗时 `0.066s`）；
  - **同字节磁盘损坏拦截**：改写单个已提交 WAV 的 1 个采样（文件大小不变），`runStartupReconciliation()` 精准定位该损坏资产，`WorkflowEngine.resume` 在推理前阻止静默信任，仅重生成该片段后续跑成功且其余片段 100% 完整（耗时 `0.031s`）；
  - **100 章 / 1,500 段高规模压测**：Sequential 防剧透百章记忆写入 + 1,500 段 DAG 执行 + 4 次瞬时故障重试 + 完成 400 段后中途取消并重开工作区续跑，**精准跳过全部 400 个已完成检查点（0 次重复执行）**，最终 1,500 个 WAV SHA-256 全部完整、孤儿/缺失/损坏均为 0，总耗时 **`2.070s`**。

### 3.2 M5 Max 真机 5 连续章节强杀恢复与自动修复实测（真实长篇小说第 1–5 章，共 97 段）

| 验收项 | 实测结果 |
|---|---|
| **P2 存量工作区无损升级** | 复制 P2 真实 `v2` 工作区执行 `sonook doctor --json \| python3 -m json.tool`，平滑升级至 `[1, 2, 3]`，既有 5 个项目与全部资产保留，`missing=0, corrupted=0, orphans=0` |
| **5 连续章节跨章记忆拆本** | `sonook analyze --chapters 1-5 --max-chars 650 --seed 42 --json \| python3 -m json.tool` 耗时 2 分 20 秒退出码 0；产出 97 段（5 章均 **100% 原文覆盖**）、5 条防剧透章节记忆（`--up-to 2` 严格只返回第 1–2 章），并在第 2 章真实抽取出主角的 1 条跨章演绎阶段演进（`stages=1`） |
| **真机 GPU 推理中途 `SIGKILL` 与恢复** | 提交 198 节点（含 2 轮自动修复）DAG 后，在 `02_tts_ch_001_seg_0008` GPU 推理中途发送真实 **`kill -9` (`SIGKILL`)**；紧接 `sonook doctor` 报告 **0 损坏、0 缺失、0 孤儿**；新进程 `sonook job resume --json \| python3 -m json.tool` 立即接管第 8 段、**跳过强杀前全部 8 个已完成节点（0 次重复推理）**，3 分 20 秒内以 RTF `0.21–0.24` 跑完 5 章 97 段合成 + 全量 ASR + 两轮自动修复，失败节点 **0** |
| **后置自动换 Seed 修复实效** | Round 1（`seed=79`）精准聚焦 7 个有 ASR 缺陷的片段，1 轮即自动将第 2 章 1 声错读段 `ch_002_seg_0005` 修至 `adjCER=0.00%` 并转正 `verified`，另将 4 段归属待审音频修至 `adjCER=0.00%`（同时诚实保留归属审核状态）、1 段显著降低 CER；Round 2（`seed=116`）自动收窄至仅剩 2 段，验证候选未更优后拒绝覆盖（`swap=false`），完好保护已有更佳音频 |
| **批量审核、改派说话人与精准缓存失效** | `sonook review list` 清晰列出待审队列；对 `ch_004_seg_0019` 执行 `review reassign <segment-id> --project <id> --speaker <角色名>` 后，`sonook cache plan` 精准报告 86/97 段 `intact_cache_hit`、仅目标段标为 `speaker_reassigned`；单段重生成 `ch_004_seg_0019` 后立刻达到 `adjCER=0.00% verified`；`review approve-all --max-cer 0.05` 一键批量通过 8 段 0% CER 引号拟声词，最终 `verify --save-report` 退出码 0（`export_ready=true`） |
| **CLI `--json` 净输出隔离** | 全部 GPU 命令（`doctor`、`analyze`、`job resume`、`segment regenerate`）及非 GPU 命令经 `\| python3 -m json.tool` 校验 **100% 退出码 0**，上游 `MLX` 调试日志全部静默归入 `stderr` |
| **标准化目录自动命名导出 5 章 M4B** | `sonook export --chapters 1-5 --format m4b`（省略 `--out`）4 秒自动落盘至 项目的 `audiobooks/` 目录（文件名以 `_ch001-005_dry.m4b` 结尾）（**10.84 MB**，**708.85s / 11 分 49 秒**，48 kHz AAC 126.7 kbps）及同名 `.timeline.json`；`afinfo` 与 Apple `AVURLAsset` 完整回读全部 **5 个中文章节标题**；收尾 `sonook doctor` 报告热状态 `nominal`、`missing=0, corrupted=0, orphans=0`；5 章连续峰值内存：`9B 5,623 MiB · VoiceDesign 10,784 MiB · VoxCPM2 10,332 MiB · ASR 4,305 MiB` |

---

## 4. 后续演进（移交 P4 通用音频与剧情音景）

- **P4 通用音频与多轨场景混音**：在 P3 长篇可靠性基座之上，扩展「剧情场景氛围（9B `SceneCue/SFXCue` 标注 + 真实 CC0 无版权自然环境音库按场景平滑切换 + 可选可插拔本地小模型 `SFXProvider` 点状音效生成与缓存复用）」、广播剧授权改编多轨混音，以及私人播客与 `KnowledgeKit`（来源检索与证据引用）。
