# Gallery

基于 [Mousecape](https://github.com/alexzielenski/Mousecape) 光标注册机制的 macOS
交互光标编辑器。重点改善日常桌面与应用之间的体验：待机、按下、按住、松手，
以及不离开应用即可完成的热点和动画编辑。

**0.1.0 是实验版本。** 已实现导入、编辑和原生光标运行路径；实际跨应用效果
需要在目标 macOS 上验证。私有接口存在版本差异，不能承诺支持所有应用。

## 当前功能

- SwiftUI 编辑器：五种状态、逐帧预览、热点点选／数值调整、显示大小和帧率。
- 替换、追加、前移、后移和删除帧；支持 PNG 序列、GIF、CUR、ANI。
- 读取 `.cape`，保存含交互设置的 `.gallery`；可导出常态 `.cape`。
- 直接从 PRTS Windows ZIP 或 `PRTS-Setup.exe` 读取嵌入动画，不执行 EXE。
- 全局与本地鼠标监听，左键快速松手中断按下动画；无键盘监听或输入注入。
- 可配置待机时间、交互开关及暂停交互的应用列表。
- 替换前原子写入恢复记录；停用、退出或注册失败时尝试恢复启用前的光标。
- 锁屏、休眠及用户切换时尽量回到常态，不追求安全界面中的交互效果。

## 构建与使用

需要 macOS 14+ 和 Swift 5.9+（Xcode 或 Command Line Tools），无外部包依赖。

```sh
bash Scripts/check.sh
bash Scripts/build.sh
open dist/Gallery.app
```

`dist/Gallery-macOS.zip` 是可分发的应用包。默认仅构建本机架构、使用临时签名，
尚未由 Developer ID 签名或公证。需要 Universal 包时：

```sh
GALLERY_UNIVERSAL=1 bash Scripts/build.sh
```

1. 首次打开仅显示编辑器，不自动修改系统光标。
2. 可先预览内置「Gallery · 光晕」主题；或导入已有 `.cape`。
3. 使用 PRTS 时，从其 [Releases](https://github.com/crowninggg/prts-cursor/releases)
   下载 Windows ZIP，在工具栏「主题 → 从 PRTS Windows 包导入交互动画」选择它。
4. 选择光标角色和「常态／待机／按下／按住／松手」，直接编辑；更改自动保存在本机。
5. 点击「应用主题」测试。若跨应用不响应，在交互设置中检查输入监控授权。
6. 点击「停用并恢复」还原启用前的光标。编辑时先暂停，修改后重新应用。

请先停用 Mousecape 的自动重应用助手。Gallery 不需要另行运行 Mousecape，
两个工具同时重新注册资源可能互相覆盖。关闭 Gallery 窗口后仍可从菜单栏控制；
真正退出时会尝试恢复光标。

## 实现边界

GalleryNative 根据 Mousecape 适配 `CGSRegisterCursorWithImages` 等私有接口，
动态查找符号，在缺失时停用运行层、保留编辑器。它替换真实光标资源，不绘制
跟随鼠标的覆盖窗口。

运行层只处理能通过图像和热点识别的已知光标。应用自绘光标、无法识别的光标、
某些忙碌光标会跳过；不会把所有未知状态强行当作箭头。重复图像的角色可能无法
准确区分。当前系统路径最多使用 24 帧，长动画会采样并保留总时长；预览保留原始帧。

PRTS 导入当前映射箭头、文本、链接、指向手势和帮助光标，并提取可用的交互动画。
此版本待机使用循环片段，尚未串接独立的待机进入／退出片段；未提供专门的拖窗
动画识别。其他 `.cape` 的原有常态角色均可导入与编辑。

当前未实现开机自动运行、App Store 发布、签名公证、锁屏交互或全应用兼容承诺。
启用前必须成功备份某个角色，才会修改该角色。进程被强制杀死时无法执行退出
恢复：重新打开后使用「恢复上次光标」，必要时注销重新登录。

## 本地文件

- `~/Library/Application Support/Gallery/current.gallery`：自动保存的当前主题。
- `~/Library/Application Support/Gallery/recovery.plist`：启用前的恢复记录。
- 导出的 `.gallery` 包含图片与交互设置，不需要手工修改配置后重新导入。

## 验证

`Scripts/check.sh` 使用独立 Swift 检查程序，不依赖 XCTest 或完整 Xcode。
覆盖快速点击、中断、待机、热点、帧序和异常文件拒绝。

可以使用用户自己下载的安装器增加真实素材集成检查：

```sh
GALLERY_PRTS_EXE=/path/to/PRTS-Setup.exe bash Scripts/check.sh
```

`Gallery.app/Contents/MacOS/Gallery --self-check` 只检查原生符号，不修改光标。
GitHub Actions 构建 Universal 应用并上传 ZIP；跨应用验证步骤见
[测试清单](Documentation/TESTING.md)。

## 许可与来源

保留 Mousecape 的**非商业许可**，见 [LICENSE](LICENSE)、
[第三方声明](THIRD_PARTY_NOTICES.md) 和 [上游记录](Vendor/Mousecape/UPSTREAM.md)。
不是 MIT 许可，也不是 Mousecape 官方版本。PRTS 和游戏素材由用户本地导入，
不随仓库或应用分发。
