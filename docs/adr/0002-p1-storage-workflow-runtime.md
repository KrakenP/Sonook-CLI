# ADR-0002：P1 引擎基建架构（SQLite 存储、持久化 DAG、资源调度与演进契约）

- **状态**：已接受（P1 Fake + 真实 MLX 端到端门禁验证通过）
- **日期**：2026-11-25
- **影响范围**：`Package.swift`、`Sources/AudioCore/`、`Sources/StorageKit/`、`Sources/WorkflowKit/`、`Sources/ModelRuntime/`、`Sources/EngineSDK/`、`Sources/SonookCLI/`、`scripts/check.sh`、`ARCHITECTURE.md`、`ROADMAP.md`
- **前置 ADR**：[ADR-0001](0001-p0-native-mlx-runtime.md)

---

## 1. 背景

P0 实测验证并拍板了 Sonook（听澜）的原生 Swift MLX 主线组合：**`Qwen3.5-9B-4bit`（默认拆本与人物画像）+ `Qwen3-TTS-VoiceDesign`（角色定妆参考音）+ `VoxCPM2-8bit`（48 kHz 参考音锁定主合成，Apache-2.0）+ `Qwen3-ASR-1.7B`（干声质检）**。

进入 P1 引擎基建，需要将 P0 的实验代码收拢为具备持久化、原子资产、检查点取消、断点恢复、资源租约与统一 SDK/CLI 边界的正式核心引擎，同时在不破坏阶段边界的前提下，为「可选背景音」与「角色成长声线微演进（音色连贯 + 语气/节奏演进）」预留干净的版本化数据契约。

---

## 2. 架构与关键选型决策

### 决策 1：6 Target 清晰分层并彻底用 `ModelRuntime` 取代 `P0Runtime`

- 正式 target 依赖严格单向无环：
  - `AudioCore`（仅 `Foundation` + `CryptoKit`，跨 macOS 14+ / iOS 17+，零 UI、零 SQLite、零 MLX）
  - `StorageKit`（仅依赖 `AudioCore` + 系统 `SQLite3`）
  - `WorkflowKit`（仅依赖 `AudioCore`，零 SQLite、零 MLX，可完全脱离 GPU 与磁盘框架单测）
  - `ModelRuntime`（直接取代 `P0Runtime`，统一托管 MLX LLM/TTS/ASR 适配器、`ModelResourceManager` 与原生 `AVFoundation` 渲染器，不双写、不并存）
  - `EngineSDK`（唯一 Application Services 组合层，封装项目管理、模型注册、诊断、Fake 与真实 MLX 工作流）
  - `SonookCLI`（薄壳入口，正式命令 100% 委托 `EngineSDK`，支持 `--json`、stderr 进度与稳定退出码）
- `scripts/check.sh` 默认在无 GPU 沙箱中构建并运行 `AudioCoreTests` + `StorageKitTests` + `WorkflowKitTests`（共 46 项测试，耗时 ~1.2s），并强制守卫全部 6 个 target 禁止引入 UI 框架、`StorageKit`/`WorkflowKit` 禁止引入 `MLX*`。

### 决策 2：采用苹果系统 `SQLite3` 零外部依赖封装 + POSIX 原子资产发布

- **SQLite 选型**：采用面向 Apple SDK 自带 `import SQLite3` 的 Swift 6 `actor SQLiteWorkspaceStore` 封装（开启 `WAL`、`foreign_keys=ON`、`busy_timeout=5000`、`BEGIN IMMEDIATE` 显式短写事务与编号 `schema_migrations` 表），替代引入外部 `GRDB.swift` 依赖。
  - **理由**：零第三方依赖与许可负担、零 Swift 6.4.x 兼容性隐患、沙箱离线秒级编译，且所有仓储接口隐藏在 `AudioCore.WorkspaceStoreProtocol` 协议之后，后续若 P3/P4 需要 FTS5 复杂查询可无痛替换内部实现。
- **磁盘资产原子提交与孤立回收**：
  - 写入流程：在同卷 `.tmp/` 以 `O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC` 创建临时文件 → 写盘并 `fsync` → 重读校验字节数与 SHA-256 → `renamex_np(RENAME_EXCL)` 原子发布至 `assets/<kind>/<sha256>.<ext>`（同哈希校验无损去重复用）→ 短写事务提交 `assets` 记录。
  - 并发与回收安全：写入方持 `.tmp/` 共享锁 `LOCK_SH`，启动清理 `runStartupReconciliation()` 持互斥锁 `LOCK_EX` 并在写事务内盘点全部引用，覆盖 rename-to-INSERT 间隙而不把磁盘 I/O 拖进 SQLite 写事务；绝不删除任何已引用的定妆音、干声、待审音频或历史资产，并对缺失/损坏引用输出精准诊断。

### 决策 3：持久化 DAG 采用 Fencing Token 代际租约与检查点安全取消

- `job_nodes` 遵循 `Pending → Ready → Running → Verifying → Completed` 与 `Retrying / Paused / Failed / Cancelled / NeedsReview` 状态机，`createJob` 内置 Kahn 环路检测。
- 每次原子领取（`UPDATE ... RETURNING`）递增 `lease_generation` 并设置过期时间；后台心跳按代号续租，失联或外部取消立即中断执行任务；过期 worker 迟到提交严格触发 `WorkflowStoreError.leaseRejected`，无法覆盖新代结果。
- `NeedsReview` 保留已落盘干声资产且阻塞 `requires_verified=true` 下游节点；`cancel` 持久化取消标记并仅取消未开始节点，已提交检查点 100% 保留；`resume` 在派发任何新节点前先校验全部 `completed` 检查点资产的 SHA-256，完好节点直接跳过（0 次重复推理）。

### 决策 4：`ModelResourceManager` 隔离模型租约与节点租约，固化段间清缓存

- 节点租约负责数据库提交权，`ModelResourceManager` 负责 Apple Silicon GPU 排他执行权与驻留内存预算（按 `ProcessInfo.physicalMemory × 0.65` 自适应计算，不写死 64 GB）。
- 优先级队列保证 `.interactive` 请求在当前安全片段边界优先于排队的 `.background` 任务获取 GPU；跨阶段切换模型（LLM → VoiceDesign → VoxCPM2 → ASR）自动卸载闲置模型并清空 MLX 缓存，且**每个片段合成结束（含异常/取消路径）强制执行 `MLX.Memory.clearCache()`**，并回写实测物理峰值至模型注册表。
- 正式锁声路径在合成前通过 `resolveVerifiedTimbreAnchorURL` 强制校验角色定妆参考音的资产存在性与 SHA-256，缺失或损坏直接失败，杜绝 P0 实验期的静默退化。

### 决策 5：预留「可选背景音」与「角色成长声线微演进」版本化契约

- **可选背景音（默认关闭）**：`ProductionOptions.ambientAudioEnabled` 与 `ChapterRenderConfig.ambientTrack: AmbientTrackSpec?` 仅参与**渲染指纹（`renderFingerprint`）**计算；干声 TTS 与 ASR 质检完全隔离于背景音配置之外。P1 请求启用背景音混音时明确返回 `NodeExecutionError.unsupportedCapability`，不在 P1 提前实现混音引擎，留待 P2/P4 按阶段落地。
- **角色成长声线微演进（音色锚点不变 + 演绎基线演进）**：
  - 在 `CharacterVoiceCard` 中向后兼容新增 `timbreAnchor: VoiceTimbreAnchor?`（绑定不可变定妆参考音资产与 SHA-256，锁定长篇核心音色连贯性）与按章生效的 `deliveryStages: [VoiceDeliveryStage]`（记录角色不同成长阶段的语气、沉稳度与语速基线，合成时与单句 `SegmentDirection` 叠加送入 VoxCPM2 `control_instruction`）。
  - 修正 P0 缓存失效缺陷：`synthesisFingerprint(...)` 仅依赖音色锚点、生效成长阶段、单句导演指令、朗读文本与模型版本，**补充角色别名或原文证据不再导致历史章节音频缓存失效**。

---

## 3. P1 门禁实测验收结果（M5 Max 64 GB）

1. **自动化单元与故障注入测试（`./scripts/check.sh`）**：46/46 全部通过（`AudioCoreTests` 28、`StorageKitTests` 6、`WorkflowKitTests` 12），覆盖 schema 迁移、双 worker 并发抢领、过期 generation 拒写、孤立文件回收、指数退避自愈、失联心跳中断、检查点取消与 2 章角色成长缓存隔离。
2. **Fake Provider CLI 全链路验收**：`doctor`、`project create`、`job submit --workflow fake-demo --fail-once 2 --run`（重试自愈通过）、`--ambient`（显式拒接未静默忽略）、`cancel → resume` 与 `doctor --json` 对账全通过（0 孤立/缺失/损坏）。
3. **真实 MLX 章节任务中途取消 + 跨进程断点续跑验收**：
   - 使用真实中文小说第 1 章（773 字 / 20 段 / 44 个持久化 DAG 节点，`9B → VoiceDesign → VoxCPM2 48 kHz → Qwen3-ASR → Render`）在第 7 个检查点主动触发取消，前 7 个已提交节点与资产 100% 保留（`doctor` 对账 `missing=0, corrupted=0`）。
   - 在全新 OS 进程中执行 `sonook job resume <job-id>`：**精准跳过全部 7 个已完成节点（`skipped_completed=7`，零重复推理）**，直接从第 6 句续跑至全章结束（VoxCPM2 48 kHz 稳态 RTF 0.22–0.24，16/20 通过，4/20 专词同音 `needs_review`，0 失败），导出 145.30s 48 kHz AAC M4A（`afinfo` 通过）。
   - 实测各模型运行物理峰值回写模型表：`Qwen3.5-9B` 5.52 GiB、`Qwen3-TTS-VoiceDesign` 10.42 GiB、`VoxCPM2-8bit` **8.95 GiB**、`Qwen3-ASR-1.7B` 4.20 GiB，全链路适配 16/24 GB 及以上 Apple Silicon 机型。
