# 猫标 CatPointer for macOS

这是一个原生 macOS 菜单栏应用，把 HappyCadogt 的“猫标”动画真正注册为
WindowServer 系统光标。它不是盖在鼠标上方的悬浮窗口：Finder、文本框和其他
应用看到的就是替换后的系统光标。

当前替换两类常用光标：

- Arrow：普通箭头及 macOS 对应别名。
- IBeam：文字输入光标及 macOS 对应别名。

应用启动后立即安装猫标；菜单栏和“设置”窗口中可以暂停、重新应用，并通过
滑杆调整尺寸与小猫动作速度。正常退出时会恢复启动前备份的系统光标。

## 外观与素材

光标图由原作者
[HappyCadogt（Bilibili @406949928）](https://space.bilibili.com/406949928)
设计和制作。本项目使用
[Tseshongfeeshur/cat-cursors](https://github.com/Tseshongfeeshur/cat-cursors)
中的原始动画帧，固定到提交
[`d3d6ca1a31510f2e5dcf2b69155fb1a5294978e2`](https://github.com/Tseshongfeeshur/cat-cursors/commit/d3d6ca1a31510f2e5dcf2b69155fb1a5294978e2)。

macOS 的私有动画光标注册接口最多接受 24 帧，因此 Arrow 和 IBeam 都使用系统
稳定上限 24 帧。四档速度共用首帧锚定的四舍五入等距采样；相邻源帧间隔始终是
5/6 帧，相比简单向下取整，完整序列的像素重建误差降低约 11.8% / 13.6%。
没有重新手绘或用近似图形替代原作。应用启动和自检时还会校验整套配置与 PNG
原文件的固定 SHA-256，确保打包素材没有被悄悄替换。

## 应用图标

Finder、Launchpad 和系统“打开方式”现在会显示完整的 CatPointer 应用图标。
图标主体直接使用原作 `Resources/Cursors/default/26.png` 的箭头与小猫，没有
让生成模型重画角色；柔和的桃橙色圆角底板用于保证浅色、深色背景和 16px 小
尺寸下仍能看清。

应用图标包含 16、32、128、256、512 和 1024 像素及对应 Retina 表示，最终
打包为 `Resources/CatPointer.icns`。可用 `make app-icon` 从保留的母版来源
重新生成。CatPointer 是菜单栏应用，因此运行时不会常驻 Dock；这是菜单栏应用
的预期行为，不代表缺少应用图标。

## 速度与资源

所有档位均由 WindowServer 直接播放。应用不使用逐帧定时器、鼠标事件监听、
跟随悬浮窗或事件注入，因此不会拦截点击、拖拽、滚轮、窗口缩放与文本选择。

- 慢速：保留 Arrow 4.29 秒、IBeam 4.62 秒的原作循环速度。
- 适中：12 FPS。
- 快速：20 FPS。
- 极致（默认）：30 FPS。

界面不需要理解 FPS：拖动四档“小猫动作速度”滑杆即可。尺寸滑杆提供
80% / 90% / 100% / 110% / 120% 五档。拖动时当前档位、刻度高亮和状态文字
会立即跟随，松手后的下一次主循环只应用最终档位，避免反复重建系统光标造成
卡顿。方向键可逐档调整，长按时会合并短时间内的重复输入；开关、状态和菜单
勾选在操作后立即更新，不会先跳回旧值。

暂停猫标后仍可调整设置，新值会保存并在重新启用时一次应用。设置窗口还提供
“恢复默认”、内联检查结果、Esc 关闭，并会记住上次窗口位置。应用在设置窗口
出现前准备好五档尺寸；其他尺寸直接从 100% Retina 原画胶片逐帧缩放，单元
测试确认与逐张源图渲染的像素完全相同。固定缓存只保存 5 个尺寸 × 2 类指针，
图像成本约 16.7 MiB。速度切换复用同一组图像，仅修改系统播放时间。系统唤醒、
会话恢复和显示器变化通知也会合并处理。Apple Silicon 实测应用空闲 CPU 为
0.0%。

详细来源、修改说明与第三方 MIT 许可证见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 和
[`Resources/Licenses/cat-cursors-MIT.txt`](Resources/Licenses/cat-cursors-MIT.txt)。
这些文件也会一起打进应用包。

## 构建与运行

需要 Xcode Command Line Tools 和 macOS 13 或更高版本：

```bash
make test
make app-icon
./Scripts/package-app.sh
open dist/CatPointer.app
```

构建结果位于 `dist/CatPointer.app`。这是本地 ad-hoc 签名的应用；首次打开时，
macOS 可能会显示常规的来源安全提示。当前随项目交付的预构建包面向 Apple
Silicon（arm64）；从源码构建时会生成当前 Mac 架构的版本。

## 权限

替换光标不需要“辅助功能”、屏幕录制或输入监控权限。应用通过 CoreGraphics /
CoreCursor 的私有 CGS 接口把动画帧注册给 WindowServer，并不读取输入框内容、
点击内容、键盘内容或屏幕画面。

## 恢复与安全

启动安装前，应用会备份被替换的系统光标。以下操作都会恢复原光标：

- 在菜单栏暂停猫标；
- 选择“退出并恢复系统指针”；
- 正常退出或收到 `SIGTERM` / `SIGINT`；
- 下次启动时发现上次遗留的备份。

如果前台应用仍缓存着退出前的最后一帧猫标，CatPointer 会先隐藏这张旧帧；用户
下一次移动鼠标时，系统会从已经恢复的 Arrow / IBeam 注册表重新取回原光标。

也可以从终端显式恢复：

```bash
dist/CatPointer.app/Contents/MacOS/CatPointer --restore
```

系统升级可能改变或移除这些未公开接口。接口不可用时，应用会停止安装并报告
错误；它不安装驱动、系统扩展或后台辅助进程，也不会修改系统文件。建议始终用
菜单栏的“退出并恢复系统指针”正常退出，避免强制结束进程。

## 许可证

CatPointer 自有的源代码和文档采用
[MIT License](LICENSE)。猫标原画、动画帧，以及包含该原画的图标和预览图不属于
CatPointer 贡献者原创；本项目依据上游 `cat-cursors` 仓库标示的 MIT License
使用并保留原作者归属。完整范围、固定来源版本和许可文本见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。分发源码或应用包时请同时
保留项目许可证和第三方许可文件。

## 自检

打包后可运行安装/恢复自检：

```bash
dist/CatPointer.app/Contents/MacOS/CatPointer --self-test
```

自检会临时安装 Arrow 与 IBeam 动画、读取 WindowServer 当前光标验证结果，
让新的 AppKit 客户端重新解析两类系统光标，逐像素核对 24 帧胶片，逐项验证
慢速、适中、快速、极致四档速度、重复应用缓存和安全备份，然后恢复原光标并
以 JSON 输出检查结果。
为避免两个实例同时管理系统光标，请先从菜单栏退出正在运行的猫标。
