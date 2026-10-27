# 版权与许可说明

## 上游项目

本项目的部分源代码基于 **Linwood Butterfly** 修改：

- 项目：Butterfly
- 上游版本：2.6.2
- 仓库：https://github.com/LinwoodDev/Butterfly
- 许可证：GNU General Public License v3.0（见 `LICENSE`）
- 原始版权：Copyright © Linwood and Butterfly contributors

本项目保留上游的 `LICENSE`、`BRANDING_LICENSE` 及源代码中的版权声明，并按 GPL-3.0 的要求公开修改后的源代码。

## 本项目修改

木木笔记在原项目基础上进行了界面、输入管线、PDF 导入导出、分页纸面与防误触等方面的修改与重新品牌化。主要新增/修改包括：

- **PalmGuard 防触碰引擎**：Flutter 服务 `app/lib/services/palm_guard_service.dart` 与原生 Android 模块 `app/android/palm-guard/`，包含触点几何判定、手掌锚点、160 ms 幽灵笔迹回滚、400 ms 主动笔护盾、虚拟手垫和双框校准。
- **木木笔记界面与中文内容**：书架、编辑器工具栏、分页纸面、PDF 工作流、内置 16 页 PDF 说明书。
- **输入与对象行为**：套索删除、橡皮提交、快捷手势开关、页面导航和缩略图渲染优化。

修改部分版权归木木笔记贡献者所有，同样按 GPL-3.0 发布。

## 商标声明

- 本项目使用“木木笔记”名称与自有图标，**未使用** Butterfly 的名称、Logo 或品牌素材。
- 本项目与 Notein（一笔记）无任何关联，未使用其商标、图标或素材。

## 第三方依赖

项目使用的 Flutter、Dart 包及其他第三方组件分别遵循其自身许可证，详见 `app/pubspec.lock` 及各包附带的 LICENSE。
