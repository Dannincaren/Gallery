# Gallery 1.0.1

## 简体中文

- 新增原生英文界面，自动跟随 macOS 语言偏好，也支持系统按应用选择语言；中文界面和旧主题数据保留。
- 翻译菜单、角色名称、编辑器、设置、导入、多素材选择、提示与错误；英文使用标记改为普通字形的 IN USE。
- 精简导入窗口。首次打开自动显示完整、可滚动的导入说明；以后点击标题旁的 ⓘ 查看。完整提示不再挤在小字中截断。
- 减少重复的状态文字、调度数组和屏幕信息查询，保留现有动画时序、缓存、帧率与鼠标事件路径。
- 仓库默认展示完整中文说明，可切换完整英文版；补充使用截图、常见问题、贡献和反馈模板。

需要 macOS 14+，包含 Apple 芯片与 Intel。解压 `Gallery-macOS.zip` 后将应用放入「应用程序」，正常停用并退出旧版再替换。应用标识与主题格式保持兼容。

包仍为临时签名，尚未 Developer ID 公证。许可继续采用 Mousecape 的非商业条款；不包含第三方光标素材。更新不会将用户主题名翻译或改写为新的系统角色标识。

验证：59 项合成核心检查；英文、简体中文和其他语言回退检查；426 条语言资源及数字、文件名占位符；隔离编辑器；系统角色常态／按下、大小、阴影及恢复。性能测量范围见 [PERFORMANCE-1.0.1.md](PERFORMANCE-1.0.1.md)。

## English

- Add a native English interface that follows macOS language preferences, including per-app language selection. Simplified Chinese and existing theme data are retained.
- Localize menus, role labels, editor/settings, imports, material selection, messages and errors. The English active-theme label uses ordinary IN USE lettering.
- Simplify the import panel. A complete, scrollable guide opens on first use and can be reopened with ⓘ beside the title; long hints are no longer truncated in the compact panel.
- Reduce repeated status formatting, temporary scheduling arrays, and screen-information queries while retaining animation timing, cache limits, frame rate and mouse event delivery.
- Make Chinese the default complete README with a complete English alternative, screenshots, FAQ, contribution guidance and issue templates.

Requires macOS 14+. The package includes Apple Silicon and Intel. Unzip `Gallery-macOS.zip`, stop and quit the previous version, and replace Gallery.app in Applications. The bundle identifier and theme format remain compatible.

The app remains ad-hoc signed, without Developer ID notarization. The retained Mousecape noncommercial license applies; no third-party cursor themes are included. User theme names and stored cursor identifiers are not rewritten by localization.

Validation includes 59 synthetic core checks; native English, Simplified Chinese and language-fallback checks; 426 table entries and interpolation of numbers/filenames; isolated editor checks; and controlled system normal/press playback, sizing, shadows and restoration. See [performance notes](PERFORMANCE-1.0.1.md) for measurement limits.

Package / 安装包：**2.47 MB ZIP**, **5.72 MB installed contents** (decimal units). Both architectures and all import features are included. Compared with 1.0.0, the bilingual package adds about 0.10 MB.
