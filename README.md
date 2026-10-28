# Gallery

基于 [Mousecape](https://github.com/alexzielenski/Mousecape) 光标注册机制的 macOS
交互光标编辑器。重点改善日常桌面与应用之间的体验：待机、按下、按住、松手，
以及不离开应用即可完成的热点和动画编辑。

**0.5.3 是实验版本。** 已实现导入、编辑和原生光标运行路径；实际跨应用效果
需要在目标 macOS 上验证。私有接口存在版本差异，不能承诺支持所有应用。
0.5.3 保持文字动画在移动时连续，并同步系统重选图像与显示分辨率；Finder 文件夹拖放松手的偶发抽动仍待处理。
版本内容与验证边界见 [0.5.3 发布说明](Documentation/RELEASE-0.5.3.md)。

## 当前功能

- SwiftUI 编辑器：五种状态、逐帧预览、热点点选／数值调整、显示大小和帧率。
- 替换、追加、复制当前帧、前移、后移和删除帧；支持 PNG 序列、GIF、CUR、ANI。
- 读取 `.cape`，保存含交互设置的 `.gallery`；可导出常态 `.cape`。
- 直接从 PRTS Windows ZIP 或 `PRTS-Setup.exe` 读取嵌入动画，不执行 EXE。
- 优先会话级只读鼠标监听；未授权时使用系统鼠标事件监听，无法监听时使用计数和位置采样，关闭编辑窗口后继续运行。
- 自动按素材决定交互：有「按住」动画时保持到松手；只有「按下、松手」时自动连播，无需额外开关。旧主题也适用。
- WindowServer 实际光标读取、标准光标缓存识别与尺寸归一化；未知状态不会关闭整个运行层。
- 可配置全局默认与各角色独立待机时间、交互开关及暂停交互的应用列表。
- 全局与单角色大小滑块（各 50%–300%，组合后最大 128 逻辑点）；保持未知应用自定义光标的原有大小。
- 每个主题独立保存为可展开的目录；兼容旧版单主题自动迁移。
- 单角色可使用系统原有光标，或复制其他主题的角色素材；混合后的主题可独立导出。
- 系统登录项与启动后自动应用主题选项，默认关闭。
- 启用主题时隐藏 Dock 图标、快速甩动时临时放大主题光标，均可独立开关。
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
3. 使用 PRTS 时，优先导入已整理的 `.gallery`；也可选择或拖入原版完整 Windows ZIP。
   EXE 必须选择「程序文件/PRTS-Setup.exe」；PRTS-Install.exe 只是入口，无法提取素材。
   同一个「导入主题」入口自动识别 `.gallery`、`.cape`、`.zip`、`.exe`。
4. 展开主题目录，选择角色和「常态／待机／按下／按住／松手」编辑；更改自动保存在本机。
   大小可直接调节；切换来源、选择系统原有光标和编辑帧前先暂停。
5. 点击「应用主题」测试。若跨应用不响应，在交互设置中检查输入监控授权。
6. 点击「停用并恢复」还原启用前的光标。编辑时先暂停，修改后重新应用。

请先停用 Mousecape 的自动重应用助手。Gallery 不需要另行运行 Mousecape，
两个工具同时重新注册资源可能互相覆盖。关闭 Gallery 窗口后仍可从菜单栏控制；
真正退出时会尝试恢复光标。

## 实现边界

常态资源通过 Mousecape 的 `CGSRegisterCursorWithImages` 路径应用，提供真实的
1x/2x/3x 图像条带并刷新 CoreCursor 缓存。可备份的 ArrowS / IBeamS 兼容别名一并注册。
命中注册的静态图像时直接使用系统资源；前台程序的旧缓存绕过注册时，用缓存的 NSCursor 补足。
运行层没有跟随窗口，也不隐藏系统光标；位置、可见性、全屏和 Spaces 合成由 macOS 管理。
交互及多帧常态通过系统光标通道提交缓存帧，最多每秒 60 次。后台识别过滤自身提交的种子，避免动画反馈为错误角色。
大小变更只调整当前缓存光标的逻辑几何，不重新生成整套条带；下次应用主题时按当前大小注册。
静态停留约每 200 毫秒检查一次；输入直接请求更新，移动本身不启动高频渲染。连续重复帧按原时长保持，不重复提交。调度中心采用常态第一帧，退出后恢复交互。
静态或不可见编辑器不刷新动画预览，启用主题时禁用播放按钮。角色缩略图一次生成并持久化，不实时播放。
私有符号动态查找，缺失时保留编辑器并报告运行层错误。

运行层识别实际 WindowServer 光标，并学习标准光标及启用前主题的图像。
包含真实箭头 CoreCursor 0 和文本 CoreCursor 1，保留所有分辨率表示。
WindowServer 动画条带按已知帧数解析并匹配首、中、尾帧。透明留白和缩放差异通过可见边界归一化处理。
应用自绘且无法识别的光标会暂时跳过；回到已知状态时恢复该类指针的交互。
不将未知状态强行视为箭头，重复图像的角色仍可能无法精确区分。原生常态及导出 Mousecape 最多使用 24 帧；交互显示和预览保留完整帧序列。

PRTS 导入包含 20 类指针、46 个资源变体（含 3 类仅素材状态）：正常、帮助、链接、后台运行、忙、精准、文本、
竖排文本、移动、候选、水平/垂直/对角调整、不可用及拖放等。编辑器按类别合并显示系统别名。
手写、定位、人员选择在 macOS 没有统一系统状态，保留为可编辑素材，不伪造全局映射。
待机目前使用循环片段，未串接独立的进入/退出片段；未提供专门拖窗动画识别。
Windows 点按/松手 ANI 的长尾冻结帧由转换器裁去，避免将实际动作拉长到约 60 秒。
原有 `.cape` 的常态角色也可导入和编辑。

自启动使用 [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)，
请先放入「应用程序」，再在「交互与应用设置」中开启；也可独立选择启动后自动应用主题。
当前未实现 App Store 发布、签名公证、锁屏交互或全应用兼容承诺。
启用前必须成功备份某个角色，才会修改该角色。进程被强制杀死时无法执行退出
恢复：重新打开后使用「恢复上次光标」，必要时注销重新登录。

## 本地文件

- `~/Library/Application Support/Gallery/current.gallery`：当前主题的兼容副本。
- `~/Library/Application Support/Gallery/Themes/<UUID>.gallery`：各主题的独立归档。
- `~/Library/Application Support/Gallery/themes.json`：目录名称、角色摘要及每角色一张最大 64 像素的缓存缩略图。
- `~/Library/Application Support/Gallery/recovery.plist`：启用前的恢复记录。
- 导出的 `.gallery` 包含图片与交互设置，不需要手工修改配置后重新导入。

## 验证

`Scripts/check.sh` 使用独立 Swift 检查程序，不依赖 XCTest 或完整 Xcode。
覆盖快速点击、中断、待机、热点、帧序和异常文件拒绝。

可以使用用户自己下载的安装器增加真实素材集成检查：

```sh
GALLERY_PRTS_EXE=/path/to/PRTS-Setup.exe bash Scripts/check.sh
```

主题使用去重的 v2 图像库保存，旧版 v1 主题可直接打开；不需要手工改配置。
可在本机生成独立 PRTS 主题（不运行 EXE）：

```sh
dist/Gallery.app/Contents/MacOS/Gallery --convert-prts /path/to/PRTS-Windows.zip /path/to/PRTS.gallery
```

桌面集成验证在另一个前台测试窗口中运行：

```sh
bash Scripts/runtime-check.sh /tmp/gallery-check /path/to/PRTS.gallery
```

请先退出 Gallery 和其他光标工具。检查程序使用独立恢复记录，验证系统图像帧、快速切换、
独立大小、点按、自身帧过滤和停用恢复；不移动鼠标、不注入系统输入、不切换应用。
调度中心采用状态注入检查，真实 Dock 悬停及三指空间切换需手工复测。

`Scripts/editor-check.sh /tmp/gallery-editor-check` 在独立目录验证迁移、目录切换、复制帧和混合角色保存。
性能基准与边界见 [性能记录](Documentation/PERFORMANCE.md)。

`Gallery.app/Contents/MacOS/Gallery --self-check` 只检查原生符号，不修改光标。
GitHub Actions 构建 Universal 应用并上传 ZIP；跨应用验证步骤见
[测试清单](Documentation/TESTING.md)。

## 许可与来源

保留 Mousecape 的**非商业许可**，见 [LICENSE](LICENSE)、
[第三方声明](THIRD_PARTY_NOTICES.md) 和 [上游记录](Vendor/Mousecape/UPSTREAM.md)。
不是 MIT 许可，也不是 Mousecape 官方版本。PRTS 和游戏素材由用户本地导入，
不随仓库或应用分发。
