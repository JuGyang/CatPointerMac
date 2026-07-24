# 猫标 CatPointer for macOS

<p align="center">
  <img src="Validation/catpointer-demo.gif" width="560" alt="猫标普通指针和文字指针动画预览">
</p>

<p align="center">
  原生、流畅、轻量的 macOS 动画猫咪鼠标指针，不影响正常点击、拖动与文字操作。
</p>

<p align="center">
  <a href="README.md">English</a>
  ·
  <a href="https://github.com/JuGyang/CatPointerMac/releases/latest">下载安装</a>
  ·
  <a href="LICENSE">MIT 许可证</a>
</p>

## 主要特点

- 在 WindowServer 层替换 macOS 普通箭头和文字输入光标。
- 使用 HappyCadogt 创作的原始猫咪动画，不以近似图形重新绘制。
- 提供 5 档指针尺寸和 4 档易懂的动画速度：慢、适中、快速、极致。
- 设置操作立即反馈，同时避免无意义地重复重建系统光标。
- 原生菜单栏应用，不监听鼠标事件、不使用指针跟随悬浮窗、不安装驱动或后台辅助进程。
- 暂停或正常退出时恢复原来的系统指针。

CatPointer 使用 macOS 未公开的光标注册接口。未来的 macOS 更新可能修改或移除这些接口；接口不可用时，应用会安全停止并显示错误。

## 系统要求

| 项目 | 支持范围 |
| --- | --- |
| macOS | macOS 13 Ventura 或更高版本 |
| 处理器 | 预构建安装包支持 Apple Silicon（arm64） |
| 系统权限 | 不需要辅助功能、屏幕录制或输入监控权限 |
| 签名状态 | Ad-hoc 签名，未经过 Apple 公证 |

当前预构建版本不包含 Intel Mac 安装包。可以在兼容的 Intel Mac 上使用 Xcode Command Line Tools 从源码编译，但该配置不在当前发布版本的测试范围内。

## 下载与安装

前往 [Releases 页面](https://github.com/JuGyang/CatPointerMac/releases/latest) 下载最新版本。

### 推荐：DMG

1. 下载 `CatPointer-v1.5.2-macOS-arm64.dmg`。
2. 打开磁盘映像。
3. 将 **CatPointer** 拖入 **Applications（应用程序）**。
4. 从应用程序文件夹打开 CatPointer。

这是未经过 Apple 公证的社区构建，macOS 首次启动时可能拦截。请按住 Control 点击应用并选择“打开”。如果仍被阻止，请进入“系统设置 → 隐私与安全性”，为 CatPointer 选择“仍要打开”。

### 备用：ZIP

下载 `CatPointer-v1.5.2-macOS-arm64.zip`，解压后将 `CatPointer.app` 移入应用程序文件夹。ZIP 与 DMG 中的应用完全相同，主要用于自动化下载或偏好压缩包的用户。

Release 同时提供 `SHA256SUMS.txt`。可用以下命令校验文件：

```bash
shasum -a 256 CatPointer-v1.5.2-macOS-arm64.dmg
```

测试环境、刘海菜单栏备用入口覆盖与安装包校验值见
[v1.5.2 验证报告](Validation/TEST_REPORT-v1.5.2.md)。

## 使用方法

CatPointer 启动后会立即安装动画指针。通过菜单栏图标可以：

- 打开设置；
- 暂停或重新启用猫标；
- 恢复系统指针并退出。

在设置窗口中拖动“指针尺寸”和“小猫动作速度”滑杆选择档位。拖动时数值和刻度高亮会立即跟随，松开后只应用一次最终档位，并短暂显示实际应用的尺寸与速度，避免把界面选择误解为鼠标效果的实时预览。

在带刘海的 MacBook 上，CatPointer 会检查爪印是否位于菜单栏右侧未被遮挡的安全区域。如果该区域已经放不下、macOS 隐藏了爪印，应用会临时保留一个 Dock 图标作为备用入口。即使菜单栏图标不可用，再次从“应用程序”打开 CatPointer 也会直接进入设置。

## 流畅度与输入安全

动画由 WindowServer 直接播放。CatPointer 不使用应用层逐帧定时器，不监听鼠标事件，不在指针上覆盖悬浮窗口，也不注入输入。点击、拖拽、滚轮、窗口缩放与文字选择仍走 macOS 原生输入路径。

| 速度 | 播放方式 |
| --- | --- |
| 慢 | 保留原动画节奏 |
| 适中 | 12 FPS |
| 快速 | 20 FPS |
| 极致 | 30 FPS |

尺寸提供 80%、90%、100%、110%、120% 五档。固定缓存只保存普通箭头和文字光标的五种尺寸，约占 16.7 MiB。Apple Silicon 实测空闲 CPU 使用率显示为 0.0%。

## 恢复系统指针

安装猫标前，应用会备份原来的系统光标注册信息。暂停猫标、选择“退出并恢复系统指针”、正常退出，或下次启动时检测到上次异常中断留下的备份，都会执行恢复。

也可以从终端显式恢复：

```bash
/Applications/CatPointer.app/Contents/MacOS/CatPointer --restore
```

启用猫标时请尽量不要强制结束进程。如果其他应用在退出后短暂保留了最后一帧动画，移动一次鼠标即可让 macOS 重新获取已恢复的系统指针。

## 从源码构建

需要：

- macOS 13 或更高版本
- Xcode Command Line Tools
- `clang`、`make`、`codesign` 和 `hdiutil`

```bash
git clone https://github.com/JuGyang/CatPointerMac.git
cd CatPointerMac
make test
make package
```

发布文件位于 `dist/`：

- `CatPointer.app`
- `CatPointer-v1.5.2-macOS-<架构>.dmg`
- `CatPointer-v1.5.2-macOS-<架构>.zip`
- `SHA256SUMS.txt`

打包后可运行完整自检：

```bash
dist/CatPointer.app/Contents/MacOS/CatPointer --self-test
```

运行前请先退出其他 CatPointer 实例。自检会临时注册两类光标，检查全部动画帧、速度档位与恢复流程，并在结束前恢复原系统指针。

## 原画与许可证

鼠标指针原画由 [HappyCadogt（Bilibili @406949928）](https://space.bilibili.com/406949928) 创作。本项目使用 [`Tseshongfeeshur/cat-cursors`](https://github.com/Tseshongfeeshur/cat-cursors) 在提交 [`d3d6ca1`](https://github.com/Tseshongfeeshur/cat-cursors/commit/d3d6ca1a31510f2e5dcf2b69155fb1a5294978e2) 中提供的原始动画帧。素材只为适配 macOS 稳定支持的 24 帧上限进行采样，没有重新绘制。

CatPointer 自有源代码和文档采用 [MIT License](LICENSE)。原画归属、上游许可和固定来源版本记录在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 中。每个应用安装包内也包含项目与第三方许可文件。

## 安全与隐私

CatPointer 不读取键盘输入、点击内容、输入框文字或屏幕画面；不安装驱动、系统扩展、启动守护进程或特权辅助程序。启动与自检时会使用固定 SHA-256 值检查光标素材和配置文件，避免资源被静默替换。

如遇到可以稳定复现的问题，请通过 [GitHub Issues](https://github.com/JuGyang/CatPointerMac/issues) 提交。
