# Gallery 1.0.3

## 简体中文

- 修复跨角色点击动画串用：某个角色的按下动画尚未结束时切换角色，新角色不会再无操作播放松手动画。按下、按住与松手各自归属于触发点击的角色；返回该角色时按原时间轴继续，不从头重播。
- 保留同一角色系统别名切换时的动画连续性，快速点击去重与跨角色松手补检测继续生效。隐藏角色不增加独立计时器，沿用现有原生光标显示通道。
- 修复登录自启动后必须打开窗口才会应用主题、隐藏 Dock 图标的问题。启动时即可按设置恢复上次启用的主题，不依赖编辑器窗口；保留恢复保护和启动时导入文件的优先级。

验证包括69项核心检查、全部光标角色两两切换的760组点击模式组合、专项系统光标检查，以及7项无窗口启动场景。点击动画修复已经本地预览并经用户复测确认。没有新增权限要求或后台更新轮询。

需要 macOS 14+，同一安装包支持 Apple 芯片与 Intel。正常停用并退出旧版后，将解压得到的 `Gallery.app` 放入「应用程序」替换。现有主题、语言、外观和启动设置继续兼容；已开启登录自启动的用户应保持原安装位置。

应用采用临时签名，尚未 Developer ID 公证。沿用 Mousecape 的非商业许可，不包含第三方光标主题。

## English

- Fix click animations leaking between cursor roles. Switching roles before a press animation finishes no longer triggers an unsolicited release animation in the new role. Press, hold, and release belong to the role that received the click; returning to it continues its original timeline without replaying from the beginning.
- Preserve animation continuity across aliases of the same role, quick-click deduplication, and mouse-up reconciliation across role changes. Inactive roles add no independent timers, and the established native cursor display path stays in use.
- Fix launch-at-login behavior that required opening a window before applying the theme and hiding the Dock icon. Startup now restores the previously applied theme according to Settings without waiting for the editor, while retaining recovery protection and document-open priority.

Validation includes 69 core checks, 760 combinations of cursor-family pairs and click modes, targeted system-cursor checks, and seven windowless startup scenarios. The click-animation fix was reviewed in a local preview and confirmed by the user. No additional permissions or periodic update polling are introduced.

Requires macOS 14+. One package supports Apple Silicon and Intel. Stop and quit the previous version normally, then replace `Gallery.app` in Applications. Existing themes, language, appearance, and startup settings remain compatible. Keep the same installation location when launch at login is enabled.

The app is ad-hoc signed and not Developer ID notarized. Mousecape's noncommercial license continues to apply. Third-party cursor themes are not bundled.
