# 安全问题 / Security

安全修复以最新稳定版本为准。 / Security fixes target the latest stable release.

请使用仓库 **Security → Report a vulnerability** 私密报告漏洞，说明版本、影响、复现步骤及最小示例。不要在公开 Issue 中附加凭据、个人日志或可利用的完整恶意安装包。兼容性或普通导入失败请使用 Issue 模板。

Gallery 将 Windows 安装包作为数据解析，不执行其中的程序或 INF 操作；读取过程包含格式、长度、路径和素材数量限制。它不是运行不可信 Windows 程序的沙箱。报告解析器问题时，可提供自行构造的最小文件。

Use **Security → Report a vulnerability** in this repository for a private report, including the affected version, impact, reproduction steps, and a minimal example. Do not post credentials, personal logs, or a complete weaponized installer in a public issue. Use issue templates for ordinary compatibility or import failures.

Gallery parses Windows packages as data without executing their programs or INF actions, with format, length, path, and material-count bounds. It is not a sandbox for running untrusted Windows programs. A small synthetic file is preferable for parser reports.
