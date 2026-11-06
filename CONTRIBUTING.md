# 参与 Gallery / Contributing

欢迎使用中文或英文反馈、讨论和提交改进。 / Feedback and contributions are welcome in English or Chinese.

## 反馈问题

请使用 Issue 模板，说明 Gallery 版本、macOS 版本、芯片类型、复现步骤及预期结果。光标问题请说明角色、前台应用、是否启用输入监控，以及静止、移动、点按或拖放中的哪种情况。导入问题请提供文件格式、大小和完整错误文字。

优先提供自行绘制的最小示例；不要上传私人信息、凭据、无权分发的主题或安装器。安全漏洞请通过仓库的私密漏洞报告入口联系维护者，见 [SECURITY.md](SECURITY.md)。

## 提交代码

1. 使用 Xcode 26.2+ 或对应命令行工具，部署目标保持 macOS 14。
2. 运行 `bash Scripts/check.sh`；修改界面文字时同时维护 `Resources/en.lproj` 和 `Resources/zh-Hans.lproj`，运行 `bash Scripts/localization-check.sh`。
3. 编辑器改动可运行 `bash Scripts/editor-check.sh /tmp/gallery-editor-unique`，使用新的测试目录。系统光标检查需先停用其他光标程序，并使用独立恢复记录；不要混在默认单元检查中。
4. 提交前检查中英文排版、取消操作与旧主题兼容；性能改动保留相同素材、倍率和动画时序，记录测量边界。

优先保证点按响应和正确性，再优化能耗与体积。避免用提高轮询、降低帧率、移除架构或素材支持换取表面提升。不要将个人开发路径、测试素材、主题库、恢复记录和调试符号加入提交。

Gallery 保留 Mousecape 的非商业许可。贡献需能够按 [LICENSE](LICENSE) 与适用的第三方许可分发；保留原有署名，勿引入不兼容的依赖或未经授权的素材。

## Reporting issues

Use the issue templates and include the Gallery version, macOS version, architecture, reproduction steps, and expected behavior. For cursor problems, include the role, foreground app, Input Monitoring state, and whether the issue involves stationary playback, movement, clicks, or drag release. For import problems, include the format, size, and exact error.

Prefer a small example drawn by you. Do not upload private data, credentials, or themes/installers you cannot redistribute. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Contributing code

1. Use Xcode 26.2+ or its Command Line Tools and keep the deployment target at macOS 14.
2. Run `bash Scripts/check.sh`. Maintain both `Resources/en.lproj` and `Resources/zh-Hans.lproj` for interface text changes, and run `bash Scripts/localization-check.sh`.
3. For editor changes, run `bash Scripts/editor-check.sh /tmp/gallery-editor-unique` with a fresh directory. System cursor checks require stopping other cursor tools and using a separate recovery journal; keep them opt-in.
4. Review both language layouts, cancellation, and older themes. Measure performance with the same material, size, and timing, and describe measurement limits.

Prioritize correct click response, then energy and size. Do not hide regressions by increasing polling, reducing frame rate, removing an architecture, or dropping format support. Keep personal paths, test artwork, theme libraries, recovery records, and debug symbols out of commits.

Gallery retains Mousecape's noncommercial license. Contributions must be distributable under [LICENSE](LICENSE) and applicable third-party terms. Preserve attribution and avoid incompatible dependencies or unauthorized artwork.
