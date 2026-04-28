# TodoFloat

macOS 原生桌面悬浮待办小工具。始终置顶，毛玻璃背景，双数据源双向同步。

## 功能

- **苹果提醒事项**：通过 EventKit 读写，勾选完成/编辑文字自动同步
- **飞书待办表**：通过 lark-cli 读写，勾选完成/编辑文字自动同步
- 双击编辑文字，回车保存
- Checkbox 勾选完成，实时写回数据源
- 5 分钟自动刷新 + 手动刷新
- NSPanel 悬浮窗口，始终置顶，可拖动
- LSUIElement — 不在 Dock 显示图标

## 编译

```bash
clang -fobjc-arc -framework Cocoa -framework EventKit \
  -o TodoFloat.app/Contents/MacOS/TodoFloat src/main.m
```

## 运行

```bash
open TodoFloat.app
```

首次运行会弹出系统权限弹窗，允许访问提醒事项即可。

## 依赖

- macOS (Apple Silicon)
- [lark-cli](https://github.com/nicepkg/lark-cli) — 飞书数据源需要

## 技术栈

Objective-C + AppKit + EventKit，单文件编译，无第三方依赖。

---

## Windows 版

Windows 版位于 [`windows/`](windows/) 子目录，使用 Python + tkinter 实现，零第三方依赖。

**功能对等：** 飞书待办表双向同步（lark-cli）、勾选完成写回、双击编辑写回、5分钟自动刷新、窗口置顶可拖动。数据源 1 用本地 JSON 文件替代苹果提醒事项（Windows 无 EventKit）。

```bash
cd windows
python todofloat.py
```

详见 [windows/README.md](windows/README.md)。
