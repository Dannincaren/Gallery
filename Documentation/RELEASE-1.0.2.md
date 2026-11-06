# Gallery 1.0.2

## 简体中文

- 每个主题新增独立的「像素风格」勾选框，位于子页面「主题整体大小」上方。启用后覆盖抗锯齿设置，切换主题时自动采用各自设置；保存完成即更新受影响的橱窗封面和角色缩略图。
- 统一橱窗、编辑器、素材预览、导出与实际光标的像素渲染规则，保留原始素材；按需预览继续使用有界缓存。
- 英文使用标识改为普通字形逐字母竖排，保留 IN 与 USE 的间隔。去掉目录顶部重复状态，统一子页面的使用中／浏览字体与对齐，修正工具栏各按钮的悬停提示。
- 设置中可手动选择简体中文、English 或跟随系统，重新打开后生效。全部设置一起滚动，并增加「退出 Gallery」，通过现有保存与恢复流程正常退出。
- 新增手动「检查更新」：仅读取 GitHub 的正式发行信息，不发送主题或账号凭据，更新仍需自行下载安装。使用固定仓库 ID，兼容仓库或账号改名。
- 导入说明分为无编号的支持格式和单独编号的使用步骤；首次打开显示完整说明，以后通过 ⓘ 查看。中英文均完整说明文件／目录、支持的 EXE／ZIP、多素材选择及失败后的替代方法。

需要 macOS 14+，同一安装包支持 Apple 芯片与 Intel。正常停用并退出旧版后，将解压得到的 `Gallery.app` 放入「应用程序」替换；主题数据与应用标识保持兼容，旧主题的像素风格默认关闭。

沿用已验证的光标播放与输入时序，不增加后台更新轮询。验证包括 61 项合成核心检查、467 项中英资源、编辑器自动保存／预览刷新／切换隔离、更新成功与失败路径，以及像素预览缓存。新增功能不宣称改善物理点按到显示的延迟。

应用采用临时签名，尚未 Developer ID 公证。沿用 Mousecape 的非商业许可，不包含第三方光标主题。

## English

- Add an independent **Pixel art** checkbox above Theme size in each theme editor. It overrides smoothing and follows the selected theme automatically. Affected covers and role thumbnails refresh when saving finishes.
- Apply the same pixel-rendering policy to gallery cards, editing and material previews, exports, and actual cursors without rewriting source artwork. On-demand previews retain bounded caches.
- Show IN USE vertically, one ordinary letter per line with the word space retained. Remove redundant gallery status, align active/browsing text in the editor, and fix individual toolbar tooltips.
- Choose English, 简体中文, or Follow System in Settings; reopen to apply. All settings scroll together. **Quit Gallery** uses the existing save-and-restore termination flow.
- Add manual **Check for Updates** through public GitHub stable-release metadata. No theme data or account credentials are sent; download and installation remain manual. A permanent repository ID keeps checks working after account or repository renames.
- Separate supported formats from numbered usage steps in the complete import guide. Show it on first use and reopen with ⓘ. Both languages explain files/folders, supported EXE/ZIP packages, material selection, and fallback options.

Requires macOS 14+. One package supports Apple Silicon and Intel. Stop and quit the previous version normally, then replace Gallery.app in Applications. The bundle identifier and existing theme data remain compatible; pixel art is off by default for older themes.

The established cursor playback and mouse-input timing remain in use, with no periodic update polling. Validation includes 61 synthetic core checks, 467 bilingual table entries, editor automatic saves/preview invalidation/theme isolation, update success and failure paths, and pixel-preview caching. This release makes no new claim about physical input-to-display latency.

The app is ad-hoc signed and not Developer ID notarized. Mousecape's noncommercial license continues to apply. Third-party cursor themes are not bundled.
