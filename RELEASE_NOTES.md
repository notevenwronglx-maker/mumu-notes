# 木木笔记 2.6.4

这是木木笔记的最终整理版本，面向 Android 平板手写笔记与 PDF 批注。

## 项目基底

木木笔记基于 **Linwood Butterfly 2.6.2**（Flutter / Dart）修改，按 **GPL-3.0** 发布。原始版权归 Linwood 及 Butterfly contributors 所有。仓库保留 `LICENSE`、`BRANDING_LICENSE` 和 `ATTRIBUTION.md`。

## 最大创新点：PalmGuard 防触碰引擎

PalmGuard 面向没有蓝牙协议、没有压感、没有笔尖 ID 的普通电容笔，在 Android 触控事件进入书写层之前完成笔尖 / 手指 / 手掌 / 侧掌 / 小指的判定：

- 接触几何判定：等效直径、长短轴偏心率、压力、速度、曲率、面积膨胀率
- 默认笔尖上限 4.2 mm、手掌硬阈值 11.5 mm，可在双框校准实验室重新采集
- 主动笔 400 ms 全屏护盾
- 160 ms 幽灵笔迹自动回滚
- 手掌锚点与左右手姿态扇区
- 强书写锁定、虚拟防误触手垫、EMA / One-Euro 自适应
- 双指撤销、三指重做、双击适配页宽、长按临时橡皮等快捷手势可单独开关

实现位于：

- `app/lib/services/palm_guard_service.dart`
- `app/android/palm-guard/`

## 本版本包含

- 内置 16 页《木木笔记快速上手指南》PDF，可直接在应用内翻页和批注
- PDF 整本导入：逐页 Area、PDF 原文层与手写批注层分离，不再生成多余模版页
- 页面平铺概览缩略图按实际尺寸 2 倍渲染，打开即清晰
- 右侧页码导航：上当前页、中间横线、下总页数
- 套索删除、橡皮提交、快捷操作开关持久化
- 全新「木木笔记」Logo、松绿品牌色、暖纸色弹窗
- 严格简体中文界面

## 安装包

- `Mumu-Notes-2.6.4-arm64-v8a.apk`：绝大多数 Android 平板
- `Mumu-Notes-2.6.4-armeabi-v7a.apk`：较老的 32 位设备
- `Mumu-Notes-2.6.4-x86_64.apk`：Android 模拟器

版本名 2.6.4；versionCode 分别为 31003 / 30003 / 33003。

## 验证

- 三套 APK 构建成功，release 签名校验通过
- 更新安装与全新安装均能生成 16 页 PDF 指南
- 3 页 PDF 导入后只显示 3 页，底部不再出现模版页
- 平铺缩略图、页码导航、快捷操作开关在 Android 平板模拟器上完成回归
- 未发现 Flutter / Android 致命异常

## 许可

GPL-3.0。请保留 `LICENSE`、`BRANDING_LICENSE`、`ATTRIBUTION.md`，分发修改版时提供对应源代码。