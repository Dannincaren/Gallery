# Gallery 1.0.1 performance / 性能记录

2026-11-06. Priorities remain click response, CPU/energy, then package size. These are small reductions in repeated work, not a new playback engine or a claim of a large whole-app energy improvement.

## Changes

- Status text is formatted and localized only when its role, motion, native/shell state or shell interaction changes. Steady playback no longer rebuilds the same strings on each render.
- The scheduler compares optional deadlines directly, avoiding two temporary arrays per call. Its polling periods, deadline arithmetic and minimum delay are unchanged.
- The renderer caches the maximum display raster scale and refreshes it on macOS screen-parameter notifications. Preparing an uncached interaction frame no longer enumerates screens for each raster request.
- The theme gallery builds its ID dictionary only while reordering. Normal browsing uses the existing library array.
- English and Chinese use native string tables, loaded by macOS. There is no locale-polling timer or translation service. Release tables are compiled to binary property lists; debug symbols remain outside the app.

No change is made to event sources, polling frequency, animation frame rate, cache budgets, registration/selection order, hold/release timing, or the native/paired-resource animation path that fixed visible jitter. Both CPU architectures and all import formats remain included. First-use import help is a static, on-demand view.

## Measurement and verification

A deadline-equivalence comparison covered **15,972 combinations**, including missing, past, simultaneous, very near, future, infinite and NaN deadlines, paused/unpaused states and both polling modes. Every result matched 1.0.0.

In a local optimized microbenchmark with **1,000,000 calls per sample**, seven samples had a median of **82.40 ms before** and **2.62 ms after** for that scheduler workload. The saving is about **0.08 microseconds per call**. It is deliberately reported as a small absolute reduction: the application does not call this function a million times during an ordinary interaction.

These numbers are **not physical mouse-to-display latency**, CPU percentage, battery power, or speedups for the whole app. No such end-to-end reduction is claimed. Rendering and OS delivery continue to dominate many cases; no polling/energy trade-off is introduced.

Validation includes 59 synthetic core checks, native bundle language/interpolation/metadata checks, isolated editor/library checks, and controlled native cursor playback/size/appearance/restoration checks. Desktop screenshots cover both language layouts. A concurrent offscreen-rendering run disrupted one short snapshot assertion; a separate sequential run passed all cursor checks and removed its recovery record. Controlled checks cannot establish behavior in every foreground application.

The [1.0.0 measurements](PERFORMANCE-1.0.0.md) describe the earlier recognition optimization. Package measurements for this bilingual release appear in the release notes.

## 中文说明

本版仅减少重复工作：状态改变时才生成文字、调度时不再创建临时数组、屏幕参数改变时才刷新倍率缓存、普通浏览不构建排序字典。语言资源由系统加载，导入说明静态显示，不增加常驻检测或播放定时器。

15,972 组调度输入与旧版结果一致。百万次调用的局部测试从中位 82.40 毫秒降至 2.62 毫秒，折合单次约节省 0.08 微秒，绝对收益较小，不能理解为每次点按节省了几十毫秒。本版没有实测整机电池功耗或物理点按到屏幕的延迟，不宣称此类提升。

保留原有播放、注册、帧率、缓存上限、按住与松手时序；不通过提高轮询换取响应。中英文和导入引导加入后仍保留 Apple 芯片／Intel 及全部导入能力。

Package / 安装包：**2.47 MB ZIP**, **5.72 MB installed contents** (decimal units). Both architectures and all import features are included. Compared with 1.0.0, the bilingual package adds about 0.10 MB.
