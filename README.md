# Gallery

基于 [Mousecape](https://github.com/alexzielenski/Mousecape) 光标注册机制的 macOS
交互光标编辑器。重点改善日常桌面与应用之间的体验：待机、按下、按住、松手，
以及不离开应用即可完成的热点和动画编辑。

**0.2.0 是实验版本。** 已实现导入、编辑和原生光标运行路径；实际跨应用效果
需要在目标 macOS 上验证。私有接口存在版本差异，不能承诺支持所有应用。
后台原生光标切换、水平调整识别及未知状态后恢复仍有未解决的问题，已记录并暂缓处理。
版本内容与验证边界见 [0.2.0 发布说明](Documentation/RELEASE-0.2.0.md)。

## 当前功能

- SwiftUI 编辑器：五种状态、逐帧预览、热点点选／数值调整、显示大小和帧率。
- 替换、追加、前移、后移和删除帧；支持 PNG 序列、GIF、CUR、ANI。
- 读取 `.cape`，保存含交互设置的 `.gallery`；可导出常态 `.cape`。
- 直接从 PRTS Windows ZIP 或 `PRTS-Setup.exe` 读取嵌入动画，不执行 EXE。
- 会话级只读鼠标监听；无权限时使用鼠标事件计数和位置采样，关闭编辑窗口后继续运行。
- 每类指针独立控制「拆分按下、按住与松手」：仅正常选择默认开启，其余默认完整播放一次点击动画。
- WindowServer 实际光标读取、标准光标缓存识别与尺寸归一化；未知状态不会关闭整个运行层。
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
3. 使用 PRTS 时，优先导入已整理的 `.gallery`；也可选择或拖入原版完整 Windows ZIP。
   EXE 必须选择「程序文件/PRTS-Setup.exe」；PRTS-Install.exe 只是入口，无法提取素材。
   同一个「导入主题」入口自动识别 `.gallery`、`.cape`、`.zip`、`.exe`。
4. 选择光标角色和「常态／待机／按下／按住／松手」，直接编辑；更改自动保存在本机。
5. 点击「应用主题」测试。若跨应用不响应，在交互设置中检查输入监控授权。
6. 点击「停用并恢复」还原启用前的光标。编辑时先暂停，修改后重新应用。

请先停用 Mousecape 的自动重应用助手。Gallery 不需要另行运行 Mousecape，
两个工具同时重新注册资源可能互相覆盖。关闭 Gallery 窗口后仍可从菜单栏控制；
真正退出时会尝试恢复光标。

## 实现边界

常态资源通过 Mousecape 的 `CGSRegisterCursorWithImages` 路径应用，提供真实的
1x/2x/3x 图像条带并刷新 CoreCursor 缓存。普通悬停使用系统指针；待机和点击状态
通过不激活、不拦截鼠标的透明层播放，并平衡系统指针的隐藏/显示次数。
这种组合避免在每次点击时重注册全局资源，也避免持续隐藏指针影响悬停类型识别。
后台隐藏使用 Gallery 自己连接的 `SetsCursorInBackground` 属性，停用后清除。
私有符号动态查找，缺失时保留编辑器并报告运行层错误。

运行层识别实际 WindowServer 光标，并学习标准光标及启用前主题的图像。
包含真实箭头 CoreCursor 0。透明留白和缩放差异通过可见边界归一化处理。
应用自绘且无法识别的光标会暂时跳过；回到已知状态时恢复该类指针的交互。
不将未知状态强行视为箭头，重复图像的角色仍可能无法精确区分。原生常态及导出 Mousecape 最多使用 24 帧；交互显示和预览保留完整帧序列。

PRTS 导入包含 20 类指针、45 个资源变体（含 3 类仅素材状态）：正常、帮助、链接、后台运行、忙、精准、文本、
竖排文本、移动、候选、水平/垂直/对角调整、不可用及拖放等。编辑器按类别合并显示系统别名。
手写、定位、人员选择在 macOS 没有统一系统状态，保留为可编辑素材，不伪造全局映射。
待机目前使用循环片段，未串接独立的进入/退出片段；未提供专门拖窗动画识别。
Windows 点按/松手 ANI 的长尾冻结帧由转换器裁去，避免将实际动作拉长到约 60 秒。
原有 `.cape` 的常态角色也可导入和编辑。

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

主题使用去重的 v2 图像库保存，旧版 v1 主题可直接打开；不需要手工改配置。
可在本机生成独立 PRTS 主题（不运行 EXE）：

```sh
dist/Gallery.app/Contents/MacOS/Gallery --convert-prts /path/to/PRTS-Windows.zip /path/to/PRTS.gallery
```

桌面集成验证在另一个前台测试窗口中运行：

```sh
bash Scripts/runtime-check.sh /tmp/gallery-check /path/to/PRTS.gallery
```

它会正常退出正在运行的 Gallery，使用单独恢复记录，在另一个前台测试进程中验证
交互显示层、松手、水平调整和未知状态恢复，然后恢复原光标与指针位置。
测试窗口只投递自己的本地移动事件，不点击、不输入，也不向其他应用发送系统输入。
不要与另一个主题工具同时运行。

`Gallery.app/Contents/MacOS/Gallery --self-check` 只检查原生符号，不修改光标。
GitHub Actions 构建 Universal 应用并上传 ZIP；跨应用验证步骤见
[测试清单](Documentation/TESTING.md)。

## 许可与来源

保留 Mousecape 的**非商业许可**，见 [LICENSE](LICENSE)、
[第三方声明](THIRD_PARTY_NOTICES.md) 和 [上游记录](Vendor/Mousecape/UPSTREAM.md)。
不是 MIT 许可，也不是 Mousecape 官方版本。PRTS 和游戏素材由用户本地导入，
不随仓库或应用分发。
