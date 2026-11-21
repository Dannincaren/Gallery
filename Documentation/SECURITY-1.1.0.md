# 1.1.0 安全审查 / Security review

审查日期：2026-11-21。范围为本仓库源码、固定版本的导入依赖、构建流程及发布包。
这是一轮源码检查、合成异常输入回归和包校验，不是独立渗透测试，也不表示不存在未知漏洞。

## 输入与权限边界

重点检查 `.gallery`、`.cape`、CUR/ANI、PNG/GIF、ZIP、PE/.NET 与 Inno Setup
的解析、图像解码、文件路径及输出；另检查更新元数据、重定向、安装包校验、恢复文件和原生接口。
Windows 程序、DLL 和 INF 命令不执行。外部进程只用于系统 unzip 和随包提供的
GalleryInno，参数直接传递，不通过 shell 拼接用户文件名。导入不修改原文件。
更新仍须点击触发，不自动安装，不增加权限、常驻服务或后台轮询。

## 本版修复

| 路径 | 风险与修复 |
| --- | --- |
| 文件读取 | 主题、索引和小型素材使用同一已打开描述符的有界读取；拒绝符号链接、FIFO、目录、空文件和超限内容，并在读取中继续检查增长。避免先检查后无界读取或阻塞在特殊文件上。 |
| 图片与主题 | 在实际解码前检查尺寸和累计像素量；单图不超过 32 MP，主题中不同图像累计不超过 128 MP。共享图像只计一次。这是输入预算，不是进程总内存硬限制。 |
| Mousecape | 限制表示数量，先验证逻辑尺寸、热点、帧数及各表示尺寸，再仅解码选中的表示，避免同时保留所有候选大图。 |
| CUR / ANI | 核对 CUR 图像的实际尺寸与目录；长 ANI 先计算最终保留序列再解码，最多 240 帧，并复用重复素材，保留循环周期。通用动画先完成累计像素检查。 |
| 归档与原生标识 | 在展开引用前限制动画状态及版本数量；拒绝非有限几何值、无效热点以及含控制字符、路径分隔符或过长的光标标识。原生快照另检查返回长度和有限坐标。 |
| .NET 单文件 | 同时限制解压后资源和压缩输入的单项／累计大小，避免伪造尺寸导致大范围复制或重复解压。 |
| Inno 元数据 | 限制单字符串 16 MiB、每头部流累计 64 MiB、向导图片数 256、头部条目总数 100,000；短读立即失败，避免按虚构长度分配及复制未填充的缓冲区。 |
| LZMA | 解码前将字典等内存需求限制为 256 MiB，拒绝过大的 LZMA1/2 配置；更新固定依赖到 liblzma 5.8.4。 |
| 子进程 | ZIP 解包设置 180 秒超时；导入子进程关闭标准输入。保留既有的选择性提取、文件名／路径检查、解压量和 Inno 超时限制。 |
| 更新检查 | 元数据按流读取，最多 2 MiB，响应无 Content-Length 时同样受限；校验最终 API 来源。 |
| 更新下载 | HTTPS 重定向和最终来源限制为 GitHub 发行资源域名、标准端口且无 URL 凭据；不发送 Cookie 或账号凭据。保留 SHA-256、实际长度、ZIP 头及原子保存，失败不覆盖原文件。 |
| 发布流程 | GitHub Actions 固定到已核对的提交哈希，checkout 不保留凭据；默认只读仓库权限。开发用资源往返／渲染入口从正式应用构建中排除。 |

### 依赖审查

XZ Utils 5.8.4 修复了官方披露的解码器重新初始化问题。该公告明确说明 raw
decoder 不受该特定问题影响；Gallery 使用 raw LZMA 解码，因此这里不把旧依赖
直接称作已经证实可利用的应用漏洞。升级用于保持依赖维护，同时另行加入与本导入路径
相关的字典内存限制。另一项旧版索引解码公告也不等于本应用存在同一路径。

来源：[5.8.4 release](https://github.com/tukaani-project/xz/releases/tag/v5.8.4)、
[GHSA-5qpq-xqfv-j9pg](https://github.com/tukaani-project/xz/security/advisories/GHSA-5qpq-xqfv-j9pg)、
[GHSA-x872-m794-cxhv](https://github.com/tukaani-project/xz/security/advisories/GHSA-x872-m794-cxhv)。
Boost 保留与现有 innoextract 相容的固定 1.85.0，并校验下载哈希。
这是与使用路径有关的审查，不是全部第三方代码的形式化安全证明。

## 验证与体积

- 核心合成回归共 96 项，包括特殊文件、尺寸伪造、累计像素、非法标识和长 ANI。
- 实际 vendor 元数据读取器与 LZMA 解码器的异常输入测试，以及正常流往返。
- 更新服务的流大小限制、来源限制、校验失败、取消、进度上限和原子覆盖回归。
- 映射、导入预览、双语资源、逐帧缓存及场景活动回归；相关测试使用隔离目录、替身或未选中的局部原生资源。
- Universal 包单独检查架构、签名、版本、依赖与解压后内容；测试不需要改写现用主题。

扩展原生循环的行为用例通过，但末尾的全局原图前后相等断言受正在运行的旧版
Gallery 干扰而未通过。独立纯只读观察在 10 秒内记录到 4 种不同箭头资源，确认
比较基线本身在变化；本轮没有为该检查停用现用应用，不将它计为完整通过。

原生备用预览 plist 从 819,369 字节无损压缩到 646,122 字节；46 个角色、108
帧的解码后 RGBA、顺序、时长和几何逐一相同。完整备用图与首次启动的本机高清缓存
均保留。不降低动画分辨率或帧率。诊断入口不进入正式二进制，调试符号独立保存。

## 保留的边界

导入助手是普通同用户进程，并非 App Sandbox 安全隔离服务；本轮没有引入重型沙箱或
保证进程总内存、CPU 的硬上限。系统 ImageIO/PDF/压缩库和私有光标接口仍依赖当前
macOS 的正确性。较大的安装器仍采用有大小上限的映射读取，不承诺防御同一用户在
解析时并发改写源文件。超限但合法的主题可能需拆分导入。

当前发行包采用 ad-hoc 签名，未做 Developer ID 公证。校验 GitHub 资源的哈希可以
发现内容不一致，不能抵御发行账号本身被攻陷。请通过[私密渠道](../SECURITY.md)报告漏洞。
Wait 超过 24 帧时采用等周期抽帧恢复，完整原始表示另存；它不是逐帧无损恢复。
系统磁盘资源不改写，异常终止后的会话恢复仍有私有接口的兼容性边界。

## English

Reviewed on 2026-11-21: repository source, pinned import dependencies, build workflow
and distribution. This combines source inspection, synthetic malformed-input
regressions and package checks; it is not an independent penetration test or a
guarantee that unknown vulnerabilities are absent.

The main attack surface is imported themes/images/installers and manual update
responses. Windows binaries and INF commands are never executed. Helper arguments
are passed directly without shell interpolation. Imports leave originals intact;
updates remain manual, with no new service, automatic installation or permission.

Hardening in this release includes:

- Descriptor-based, bounded reads for themes, indexes and small assets; rejection
  of symlinks, special files, empty/oversized input and growth during reading.
- Pre-decode image dimensions and aggregate budgets: 32 MP per image and 128 MP
  across distinct images per theme. Shared images count once. These are input
  limits, not a process-wide memory quota.
- Cape representation bounds and metadata-first selection, CUR dimension checks,
  and ANI timeline sampling before decoding at most 240 retained frames.
- Archive reference/variant limits, finite geometry and valid hotspots, and
  restricted native identifiers. Native snapshots also validate lengths/coordinates.
- Separate stored/decompressed bounds for .NET bundles; bounded Inno strings,
  image/table counts and short-read handling; raw LZMA dictionary memory capped
  at 256 MiB. Normal decoder round-trips are tested alongside malicious headers.
- A 180-second ZIP subprocess timeout and closed import stdin, retaining selective
  extraction, path checks, output budgets and the existing Inno timeout.
- Streamed 2 MiB release metadata limits and HTTPS source checks; download redirects
  restricted to GitHub release hosts without credentials. Digest/length/ZIP checks,
  cancellation and atomic destination replacement remain in place.
- Commit-pinned CI actions, read-only workflow permissions and no persisted checkout
  credentials. Developer round-trip/render commands are excluded from production.

liblzma is updated to 5.8.4, with verified source hashes. Upstream explicitly
excludes raw decoding from the reinitialization advisory linked above, so this
review does not claim that specific vulnerability was exploitable in Gallery.
Boost remains pinned at 1.85.0 for innoextract compatibility. Dependency review
does not constitute exhaustive verification of third-party code.

Validation covers 96 core cases, actual vendor parser/decoder tests, update failures
and cancellation, mappings, previews, localization, frame caches and scene activity,
plus Universal package/signature inspection. Extra native-loop behavioral cases
passed, but their final global-reference equality assertion did not: the running
older Gallery changed the baseline. A separate read-only 10-second observation
recorded four different Arrow resources. This check is not reported as fully
passing; the user's running app was left intact. All 46 native fallback roles and 108
frames survive lossless recompression: 819,369 → 646,122 bytes, with identical
decoded pixels, order, timing and geometry. Full fallbacks and the local high-quality
OS cache are retained. Animation quality is unchanged; symbols remain separate.

Residual limits: helpers are ordinary same-user processes, not sandbox services;
there is no hard overall CPU/memory quota. System image/PDF libraries and private
cursor APIs remain OS dependencies. Bounded large-file mapping does not protect
against a same-user concurrent source rewrite. Legitimate oversized themes may
need splitting. Releases remain ad-hoc signed and unnotarized; asset hashes cannot
protect against a compromised release account. Wait restoration above 24 frames
uses equal-cycle sampling with the full original kept separately, not exact frame
restoration. System files on disk stay unchanged. Use [private reporting](../SECURITY.md)
for security findings.
