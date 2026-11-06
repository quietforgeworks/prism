# Prism

**复制过的文字、图片和灵感，值得随时找回来。**

Prism 是一款住在 Mac 菜单栏里的剪贴板工具。用历史检索找回刚才的内容，把常用片段收藏起来，从图片中识别文字，再顺手粘贴回正在做的事。少一点来回翻找，多一点连贯的思路。

## 它能帮你做什么

- 搜索剪贴板历史，整理分类与收藏。
- 识别图片中的文字，减少手动重打。
- 使用快捷键、粘贴队列和快速粘贴衔接工作。
- 在本机保存历史，并按需导入、导出备份。

## 下载与安装

**macOS 26 及以上，仅支持 Apple Silicon（arm64）。**

前往 [Releases](https://github.com/quietforgeworks/prism/releases) 下载 `Prism-1.0.8-macOS-arm64.zip`，解压后将 `Prism.app` 放入“应用程序”。应用不包含在仓库的源码目录中。发布页同时提供完整源码 ZIP 和 SHA-256 校验文件。

当前应用为 ad-hoc 本地签名，未使用 Apple Developer ID 签名，未通过 Apple 公证，macOS 可能阻止首次打开。请核验来源和 SHA-256，不要全局关闭系统安全保护。尚未完成独立的全新 Mac 安装、升级和权限回归测试。

## 数据与隐私

历史记录保存在本机，但剪贴板可能包含密码和其他敏感内容。数据库与导出备份没有应用层加密，处理敏感内容前请暂停采集，并认真检查要分享的备份。

**链接预览会联网。** 打开预览时，WebKit 会访问所选网址，目标站点会收到正常浏览器请求及 IP 等信息。Prism 不能被描述为完全离线或绝对安全。

完整的采集、保留、清理和权限行为，请阅读 [使用与构建说明](Source/README.md) 和 [隐私说明](Source/PRIVACY.md)。

## 开源与构建

源码、构建脚本和完整说明位于 `Source/`。在符合要求的 Mac 上，可进入该目录后运行 `bash Build.command`；具体工具链要求见 [Source/README.md](Source/README.md)。

本项目采用 [MIT 许可证](LICENSE)。依赖与来源说明见 [Source/THIRD-PARTY.md](Source/THIRD-PARTY.md)。
