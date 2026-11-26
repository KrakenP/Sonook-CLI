# ADR-0005: P4 通用音频、剧情自适应音景与私人播客（KnowledgeKit）

- **状态**：已通过（M5 Max 64GB 真机三模态全链路验收通过）
- **日期**：2026-11-26
- **前置基线**：[ADR-0001](0001-p0-native-mlx-runtime.md)、[ADR-0002](0002-p1-storage-workflow-runtime.md)、[ADR-0003](0003-p2-audiobook-mvp.md)、[ADR-0004](0004-p3-long-form-reliability.md)

---

## 1. 背景与目标

P3 完成后，Sonook（听澜）已具备长篇多人有声小说（原文保真干声模式）的可靠性基座。P4 的目标是在**不建设多套独立引擎**的前提下，将引擎扩展为面向多种音频形态的通用生产平台：

1. **剧情自适应场景音景（Story-Aware Soundscapes）**：替代单一静态背景音，按剧情文本自动识别场景切换与点状音效，使用真实无版权（CC0 / Public Domain）自然录音叠加淡入淡出与人声闪避，且绝不破坏已有干声 WAV 缓存。
2. **可插拔本地小模型点状音效边界（`SFXProvider`）**：通过 `AudioCore` 契约与隔离本地子进程桥接，支持接入外部小模型（如 Stable Audio Open Small）按需生成点状音效并缓存复用，同时将社区/非 Apache-2.0 权重严格隔离在核心仓库之外。
3. **授权广播剧改编（`AudioDramaAdapter`）**：在用户显式授权下将纯拟声/声景旁白压缩为时间锚定音效，同时保留角色对白与完整 UTF-8 原文字节溯源。
4. **私人播客与知识库（`KnowledgeKit`）**：个人 Markdown/文本笔记入库分块、混合检索（SQLite FTS5 + 中文双字匹配）、区分事实与推断的严格引用校验，产出标准 `ScriptDocument` 直接复用现有 TTS → ASR → 自动修复 → M4B 生产管线。

---

## 2. 关键架构决策

### 2.1 `AudioCore` 通用契约与零 MLX 分层延续
- 在 `Sources/AudioCore/UniversalAudioContracts.swift` 新增版本化契约：`ProductionMode`、`SceneAtmospherePreset`、`SceneCue`、`SFXCue`、`ChapterSoundscapePlan`、`SoundLibraryManifest`、`SFXProvider`、`AdaptationAuthorization`、`AdaptedSegmentOrigin`、`AudioDramaScriptDocument`、`KnowledgeSourceRecord`、`KnowledgeChunk`、`KnowledgeCitation`、`PodcastEpisodePlan`、`SoundscapeStoreProtocol` 与 `KnowledgeStoreProtocol`。
- 新增 `KnowledgeKit`（仅依赖 `AudioCore`、`StorageKit`），纳入 `scripts/check.sh` 红线扫描（禁止引入 UI 与 `MLX*` 框架）。

### 2.2 `StorageKit` `v3 → v4` 迁移与中文混合检索
- `StorageKitInfo.schemaVersion` 升至 `4`，新增 `soundscape_plans`、`knowledge_sources`、`knowledge_chunks`、`knowledge_chunks_fts`（SQLite FTS5 `unicode61`）与 `podcast_plans` 表；`v1 → v2 → v3 → v4` 顺序迁移保留存量数据并在失败时整体回滚。
- 检索层结合 FTS5 与确定性 CJK 双字/词项评分，确保中文词组与子串检索稳定命中。

### 2.3 反幻觉剧情音景规划与安全多轨混音
- `NarrativeKit/SoundscapePlanner` 支持 9B LLM（`temperature=0.0, seed=42`）与确定性词法规划器双路径；内置**反幻觉环境守卫**：若模型在无原文依据的片段输出雨声/雷声/篝火等预设，自动回退为基于原文依据的判定或 `.none`（晴天不误配雨声，内心独白留白）。
- `AudioRenderKit/SoundLibraryRegistry` 强制路径穿越/符号链接越界拦截、SHA-256 完整性核验与许可证审计（自动选材仅限 `CC0-1.0` / `Public-Domain`，其余许可显式审计标注不静默混用）。
- `AudioRenderKit/SFXProviderBridge` 通过 `SubprocessSFXProvider`（无 shell 拼接，仅传递 JSON 请求文件、对超时或取消的进程执行终止）和 `SFXAssetResolver` 实现「本地 CC0 库 → 工作区缓存键复用 → 可选本地 SFX helper」三级解析，并将许可证与来源写入 WAV 资产元数据。
- `AudioRenderKit/SoundscapeMixer` 按帧映射多场景循环底噪、等功率交叉淡化、人声包络闪避、`.before`/`.during`/`.after` 点音效叠加与 `-1 dBTP` 真峰值限幅；渲染指纹绑定干声哈希 + 音景摘要 + 解析素材哈希，开启或调整音景**零破坏干声 WAV 资产**。

### 2.4 三模态共享同一套生产工作流
- 有声书（`audiobook`）、广播剧（`audio_drama`）与私人播客（`podcast`）最终均落盘标准 `ScriptDocument` + `ChapterRecord` + `CharacterVoiceCatalog`，100% 复用既有 `sonook generate --run`（VoiceDesign 音色锚点 → VoxCPM2 48 kHz 合成 → Qwen3-ASR + F0 音高漂移质检 → 2 轮自动换 Seed 修复）→ `verify` → `export`。
- 播客离线稿在保留原始 Markdown `quotedExcerpt` 字节溯源的同时，自动清理 `spokenText` 中的 Markdown 链接、标题井号与代码标记，避免 TTS 误读路径与符号。

---

## 3. 验证与真机实测结论

### 3.1 自动化检查与集成测试
- `./scripts/check.sh` 全部 **9 个测试目标、138 项单元测试**（含 `v1→v4` 迁移与回滚、中文/英文混合检索、防注入与防幻觉引用、晴天反雨声守卫、未授权广播剧拦截、路径穿越与符号链接拦截、外部子进程超时/取消强杀、双场景交叉淡化/人声闪避/点音效定位/M4B 回读）100% 通过。
- `Tests/Integration/universal_audio_cli.py` 在 Release 二进制 `.build/release/sonook` 上通过完整端到端 CLI 集成测试（并修复了 `PCMCodec.readMonoSamples` 在 `file.framePosition == file.length` 时的跨 SDK WAV 读尾兼容问题）。

### 3.2 M5 Max 64GB 真机三模态实测（`Qwen3.5-9B + VoiceDesign + VoxCPM2-8bit + Qwen3-ASR`）

| 验收门禁 | 实测结果 |
|---|---|
| **P3 存量工作区无损升级 `v3 → v4`** | `sonook doctor --json` 在 5 章压测工作区平滑升级至 `v4`，`missing=0, corrupted=0, orphans=0`，热状态 `nominal` |
| **Gate A：5 章真实小说 9B 剧情音景 + 多轨 M4B** | 真 9B 为 5 章规划出 **16 条 `SceneCue` + 14 条 `SFXCue`**：晴天场景未误配雨声，跨场景环境音和点音效按提示切换，无环境描写的场景保持 `none`；接入本地 Public Domain 真实自然录音导出 `ch001-005_soundscape.m4b`（712.05s，5 章回读通过，`ambient_mixed=true`，5 处雷声点音效全部解析，全部 97 段干声 WAV SHA-256 零变动） |
| **Gate B：私人播客（`KnowledgeKit` + 共享管线）** | 导入两份中文 Markdown 笔记 → 中文检索命中 Top 4 → 双人主播（`host_a` / `host_b`）6 段 3 条原文引用脚本 → 共享 `generate --run`（2 轮自动修复将 3 段高 CER 全修至 `0.00%`）→ **`verified=6/6, export_ready=true`** → 导出 28.47s 双人播客 `.m4b`（48 kHz，章节回读通过） |
| **Gate C：授权广播剧改编 + 多轨音景 M4B** | 未带 `--authorize` 调用 `sonook drama adapt` 被非零退出码明确拦截；显式授权后保留人物对白并压缩 2 处纯拟声旁白为锚定音效（5 场景 + 5 点音效）→ 共享 `generate --run` 中端侧 `pitchDrift` 守卫自动拦下 2 段旁白音高跳变并在 2 轮换 Seed 内全修至 `adjCER=0.00%` → **`verified=11/11, export_ready=true`** → 导出 43.13s 多轨广播剧 `.m4b`（`ambient_mixed=true`，2 处雷声点音效解析） |

---

## 4. 后续演进（移交 P5 服务与协同）

- **P5 服务与协同**：在 P4 多形态音频引擎基座之上，建设默认回环绑定的 `EngineServer`（配对认证、任务事件流）、`DistributionKit`（开放 `.audiopack` 格式与离线播放事件去重同步）以及防剧透上下文查询接口。
