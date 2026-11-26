# ADR-0006: P5 本地服务、`.audiopack` 开放分发与离线同步、防剧透上下文查询

- **状态**：已通过（175 项单元测试 + 实时回环客户端 8 项验收 + M5 Max 真机 5 章 `.audiopack` 与真 9B 防剧透问答验收通过）
- **日期**：2026-11-26
- **前置基线**：[ADR-0001](0001-p0-native-mlx-runtime.md)、[ADR-0002](0002-p1-storage-workflow-runtime.md)、[ADR-0003](0003-p2-audiobook-mvp.md)、[ADR-0004](0004-p3-long-form-reliability.md)、[ADR-0005](0005-p4-universal-audio-and-soundscapes.md)

---

## 1. 背景与目标

P4 完成了有声书（含剧情音景）、广播剧与私人播客三模态共享引擎。P5 面向未来 Mac / iPhone / CarPlay 跨设备协同，先在引擎层把**权威发布格式、离线同步协议、最小权限本地服务和防剧透上下文查询接口**全部做实并通过测试客户端验收（仍不提前开发正式 GUI App）：

1. **开放分发格式 `.audiopack`（`DistributionKit`）**：版本化、内容可校验、可分章按需下载，且默认剥离声音克隆原始样本、密钥、模型权重和本地绝对路径。
2. **离线播放事件同步与跨版本进度迁移（`PlaybackSyncEngine`）**：支持断网记录事件、重连幂等去重、保护主动回退/重听不被 `max(position)` 覆盖，并在节目重新发布时按 `segmentID` 精准迁移听书进度。
3. **默认回环本地服务与显式配对认证（`EngineServer`）**：零第三方网络依赖，默认仅绑定 `127.0.0.1`，提供一次性配对码交换可撤销最小权限 Bearer 令牌、分章 `Range` 断点续传下载与 SSE 实时事件流。
4. **防剧透上下文查询与独立交互会话（`SpoilerSafeContextResolver`）**：严格按当前章节与段内位置截断证据、过滤未来角色与声线阶段，并配备输出泄露守卫拦截模型参数记忆剧透。

---

## 2. 关键架构决策

### 2.1 `AudioCore` 跨端契约与 `StorageKit` `v4 → v5` 迁移
- 在 `Sources/AudioCore/ServiceAndSyncContracts.swift` 定义纯 `Foundation + CryptoKit` 跨平台契约（可供未来 iOS 客户端直接复用），涵盖 `AudioPackManifest`、`AudioPackMetadata`、`AudioPackChapterTranscript`、`AudioPackCharacterSummary`、`AudioPackChecksums`、`PublishedReleaseRecord`、`AuthScope`、`PairingChallengeRecord`、`PairedDeviceRecord`、`PlaybackEvent`、`PlaybackCursor`、`SyncMergeReport`、`SpoilerSafeContextRequest/Response`、`InteractionRecord` 及 `DistributionStoreProtocol`、`AuthStoreProtocol`、`SyncStoreProtocol`。
- `StorageKitInfo.schemaVersion` 升至 `5`，新增 `published_releases`、`pairing_challenges`、`paired_devices`、`playback_events`、`playback_cursors` 与 `interactions` 6 张表：`v1 → v2 → v3 → v4 → v5` 顺序迁移无损保留旧数据并在失败时整体回滚；`consumePairingChallenge` 采用条件更新保证单次消费原子性，`appendPlaybackEvent` 通过 `(device_id, event_id)` 主键 `INSERT OR IGNORE` 保证幂等去重。

### 2.2 `DistributionKit` 开放音频包与安全校验
- `AudioPackWriter` 原子写入 `<Title>_v<N>.audiopack/` 目录（`manifest.json` `format_version=1`、`metadata.json`、`chapters/NNN.m4a`、`transcripts/NNN.json`、脱敏 `characters.json`、`timeline.json`、播客可选 `references.json` 与全量 SHA-256 `checksums.json`），明确拒绝将 `VoiceTimbreAnchor` / 本地路径 / 密钥写入公开角色清单。
- `AudioPackValidator` 对所有导入包执行不可信输入检查：拦截未知 `format_version`、路径穿越（`..` / 绝对路径 / 符号链接逃逸）、超限文件、禁用私密文件（`.sqlite`/`.key`/`.pem`/`voice_audition`）与任意单字节 SHA-256 篡改。
- `PlaybackSyncEngine` 按 `(实际时间戳, deviceSequence, eventID, deviceID)` 因果序合并事件：显式 `.rewind` 或同一发行版、同一章内向较早位置的 `.seek` 会合法回退游标并计入 `rewind_preserved_count`，迟到旧事件不会覆盖新游标；新版本发布时 `migrateCursor(_:from:to:)` 优先按 `segmentID` 保留段内毫秒偏移迁移进度。

### 2.3 `EngineServer` 零依赖原生本地服务与最小权限安全边界
- 基于 Apple Network.framework + Swift Concurrency 实现原生 HTTP/1.1 + SSE 服务（零新增外部 SPM 依赖，不引入 UI 或 MLX）。
- **默认回环与 LAN 强保护**：默认仅绑定 `127.0.0.1`；未显式开启 `allowLAN` 时拒绝非回环地址（`.lanBindingForbidden`），开启 `allowLAN` 但未配置 TLS 证书时拒绝明文监听（`.tlsRequiredForLAN`）。
- **显式配对与可撤销令牌**：6 位配对码与 256-bit Bearer 令牌在数据库中**仅存 SHA-256 哈希**，日志绝不打印明文；按 `AuthScope`（`catalog:read` / `media:download` / `playback:sync` / `context:query` / `jobs:manage` / `admin`）执行最小权限校验，撤销设备后后续请求立即返回 `401`。
- **安全媒体断点下载**：`GET /v1/releases/{id}/files/{path}` 强制规范化路径隔离在已注册发行包目录内（路径穿越返回 `400/403`），支持 `Range: bytes=start-end` 返回 `206 Partial Content`、`Content-Range` 与 `ETag`（SHA-256）。

### 2.4 `SpoilerSafeContextResolver` 双层防剧透
- **检索层硬隔离**：`allowSpoilers == false` 时仅查询 `chapterNumber <= maxChapterNumber` 的章节与 `chapterMemoriesUpTo`，若指定 `maxSegmentID` 则进一步截断同章后续片段，并剔除未来章节才出场角色、未来别名与未来演绎阶段。
- **输出层防泄露守卫**：利用仅出现在未来章节的角色名和章节标题构建观察表，一旦模型回答触发参数记忆剧透，自动标记 `spoiler_filter_triggered = true` 并回退为严格基于已听章节证据的安全回答；仅在用户显式开启 `--allow-spoilers` / `allow_spoilers: true` 时解锁全书上下文。交互记录独立写入 `interactions`，保留播放恢复锚点且绝不改写当前播放游标。

---

## 3. 验证与真机实测结论

### 3.1 自动化测试与实时客户端集成测试
- `./scripts/check.sh` 全部 **11 个测试目标、175 项单元测试**通过（架构红线零违例；`EngineServerTests` 12 项真实回环 HTTP/Range/SSE/配对/撤销测试在 `0.041s` 内通过）。
- 两个端到端 Release CLI 集成套件全绿：
  - `Tests/Integration/universal_audio_cli.py .build/release/sonook`（P4 回归通过）
  - `Tests/Integration/p5_server_sync_client.py .build/release/sonook`：真实拉起 `sonook serve` 完成 8 项联调——健康检查、一次性配对码与重放拦截、两段式 HTTP `Range` 206 分章下载并核对 SHA-256、路径穿越拦截、实时 SSE `playback_synced` 推送、离线回退保护与重复提交 100% 去重、防剧透 vs 显式解锁查询、设备撤销立即 `401` 与 `SIGTERM` 优雅退出。

### 3.2 M5 Max 64GB 真机 5 章实战验收（`Qwen3.5-9B` + 真实 5 章音景工作区）

| 验收项 | 实测结果 |
|---|---|
| **存量 `v4 → v5` 无损升级** | `sonook doctor --json` 在 5 章真实小说工作区平滑升级至 `0.5.0-p5` / `v5`，`missing=0, corrupted=0, orphans=0`，热状态 `nominal` |
| **5 章剧情音景 `.audiopack` 发布与校验** | `sonook publish --chapters 1-5 --soundscape --sound-library ...` 产出 首版发行包（**11.15 MB**，707.25s，5 章 48 kHz M4A + 5 份逐段时间戳转录 + `manifest.json`/`metadata.json`/`characters.json`/`timeline.json`/`checksums.json`，共 14 份文件 SHA-256 全部通过 `sonook pack verify`）；审计确认 `characters.json` 零 `timbre_anchor`、零 `voice_audition`、无本机绝对路径 |
| **真机 9B 防剧透查询与显式解锁** | 从第 2 章询问首次出现在第 4 章的人物与事件。默认截断 **1,029 个未来章节**，仅返回前两章已知人物，输出守卫触发 `spoiler_filter_triggered=true`。显式开启 `--allow-spoilers` 后，`withheld_future_chapters=0`，模型能回答同一问题。 |

---

## 4. 后续演进（移交 P6 Engine 1.0 开源发布）

- **P6 Engine 1.0** 的安装与卸载契约、公开接口、许可和发布审计见 [ADR-0007](0007-p6-engine-1-0-release.md)。
