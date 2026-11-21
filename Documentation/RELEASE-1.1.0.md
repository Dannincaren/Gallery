# Gallery 1.1.0

## 简体中文

本版将此前本地测试的自定义映射、动画与性能改进带入正式发行，并加固导入和更新下载。
支持 macOS 14+，包含 Apple 芯片与 Intel 的 Universal 应用。

### 主题与映射

- 点击角色侧栏顶部的主题名称，集中调整像素风格、整体大小、重命名、导出与删除。
- 图形连线映射 46 个详细 macOS 角色；一份主题素材分配给多个系统角色后，各自大小与动画独立。
- 支持实时素材预览、多版本选择、撤回、恢复导入分配和缩略图确认；删除未用素材只清理应用内当前主题副本。
- 原生参考图优先从本机只读系统文件生成高清缓存，并保留完整备用预览，不会混入已启用主题的图案。
- 预览按素材自适应，同组接近的倍率选取较小值；侧栏按主题原有名称归类，未分配素材可直接定位。
- 仅锁定正在使用主题的映射编辑，其他主题可正常调整；大小到达实际限制时保持边界值并提示。

### 动画、响应与日常使用

- 优化帧缓存、后台图像准备及确认调度；点按、按住和松手由各角色独立处理，减少重复栅格化。
- 修复重复姿势较多的常态动画抽动与待机顺序问题；一次性精确期限改善全屏游戏模式下的动画掉帧。
- 切屏完成视为移动：回到常态并重新等待待机；调度中心打开时保持常态。不增加触控板专用检测或键盘监控。
- 等待角色使用原生系统播放与定位，替代旧软件跟随浮层；超过 24 帧的原生等待动画采用等周期抽帧恢复，完整原图另行备份，磁盘系统资源不变。
- 启用后 4 秒内不可停用，停用后 1 秒内不可启用，避免重复操作；修复登录自启动时主题及 Dock 隐藏的初始化。
- 完善导入说明、预览按钮、双语排版、语言设置与退出入口。
- 可在设置内手动检查并直接下载安装包，支持进度、取消和校验；安装仍由用户正常替换应用，不含自动更新或提权服务。

### 安全与体积

- 加固文件、归档、图片及 Inno/.NET 解析边界，限制解码像素、元数据与 LZMA 内存；更新 liblzma 至 5.8.4。
- 限制更新元数据流大小及 GitHub 下载重定向来源，保留摘要校验和原子保存。
- 完整原生备用预览无损减少约 173 KB，移除正式构建中的开发诊断入口；不降低素材分辨率或动画帧率。
- 详见[安全审查](SECURITY-1.1.0.md)、[映射说明](CURSOR-MAPPING.md)、[性能记录](ENERGY-OPTIMIZATION.md)与[更新说明](UPDATES.md)。

从本发行页下载 `Gallery-macOS.zip`；`SHA256SUMS.txt` 提供校验值。先在旧版停用主题并正常退出，再替换应用，原有主题库保留。发行包采用 ad-hoc 签名，尚未 Developer ID 公证。私有 macOS 接口、应用自绘光标及异常退出恢复仍有兼容性边界。

## English

This release brings the locally tested mapping, animation and performance work
to the stable channel, with hardened imports and update downloads. The Universal
app supports Apple Silicon and Intel on macOS 14 or later.

### Themes and mapping

- Click the theme heading in the role sidebar for pixel style, overall size,
  rename, export and deletion.
- Visually connect 46 detailed macOS destinations. Multiple destinations using
  one source receive independently editable size and animation configurations.
- Live material previews, variants, undo, import-assignment reset and thumbnail
  confirmations. Removing unused assets affects only the current in-app copy.
- Native reference previews use a high-quality cache from local read-only OS
  files plus complete bundled fallbacks, independent of active theme replacements.
- Adaptive material previews share the smaller factor when scales are close.
  Source-name sidebar groups retain unassigned artwork and navigate to its card.
- Only the active theme's mapping is locked. Actual size limits clamp both the
  value and control, with visible boundary feedback.

### Animation, response and daily use

- Bounded frame reuse, background preparation and confirmation scheduling reduce
  repeated raster work. Press/hold/release ownership stays independent per role.
- Fix repeated-pose normal-animation jumps and idle order issues. Strict one-shot
  deadlines improve animation scheduling in fullscreen Game Mode.
- Completed Space switches count as movement, returning to normal with a fresh
  idle delay; Mission Control keeps the normal pose while open. No trackpad-only
  detector or keyboard monitoring is added.
- Native Wait playback and positioning replace the software-follow overlay.
  Native originals above 24 frames restore through equal-cycle sampling, with
  full originals backed up separately. System files on disk are unchanged.
- Apply prevents Stop for four seconds; Stop prevents Apply for one second.
  Fix windowless login startup for theme restoration and Dock hiding.
- Refine import guidance, preview buttons, bilingual layout, language settings
  and the explicit Quit control.
- Manually check and download updates inside Settings, with progress, cancellation
  and integrity checks. Installation still uses normal user-driven app replacement;
  there is no automatic updater or privileged service.

### Security and size

- Harden file, archive, image and Inno/.NET boundaries, decoded-image budgets,
  metadata counts and LZMA memory. Update liblzma to 5.8.4.
- Bound streamed metadata and restrict GitHub download redirects, preserving
  digest checks and atomic destination replacement.
- Losslessly reduce complete native fallback previews by about 173 KB and exclude
  developer diagnostic commands from production, without lowering frame rate or
  image resolution.
- See the [security review](SECURITY-1.1.0.md), [mapping guide](CURSOR-MAPPING.md),
  [performance notes](ENERGY-OPTIMIZATION.md) and [download behavior](UPDATES.md).

Download `Gallery-macOS.zip` and verify it with `SHA256SUMS.txt`. Stop the theme and
quit the old version normally before replacing the app; the existing library is
retained. This release is ad-hoc signed, not Developer ID notarized. Private macOS
APIs, app-drawn cursors and recovery after abnormal termination retain compatibility
limits.
