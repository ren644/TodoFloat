# TodoFloat for Windows

Windows 版桌面悬浮待办小工具。始终置顶，半透明深色背景，双数据源双向同步。

## 截图预览

```
┌─────────────────────────────┐
│ ☑ 待办          ＋  ⟳ 刷新  │
├─────────────────────────────┤
│ 📋 本地待办 (2)              │
│ ● ☐ 写周报                  │
│ ● ☐ 买咖啡                  │
│─────────────────────────────│
│ 📅 飞书待办 (3)              │
│ ● ☐ 产品评审准备     04-28   │
│ ● ☐ 修复登录Bug      04-29   │
│ ● ☑ 设̶计̶稿̶确̶认̶       04-27   │
├─────────────────────────────┤
│  更新于 14:30:00 · 5分钟刷新  │
└─────────────────────────────┘
```

## 功能

- **飞书待办表**：通过 lark-cli 读写，勾选完成/编辑文字自动同步
- **本地待办**：JSON 文件存储（`~/.todofloat/local_todos.json`），支持增删改查
- 双击编辑文字，弹窗修改后保存
- Checkbox 勾选完成，实时写回数据源
- 状态圆点：🟠 待做 / 🔵 进行中 / 🟢 已完成
- 5 分钟自动刷新 + 手动刷新按钮
- 窗口始终置顶，半透明，可拖动
- 深色主题，中文界面

## 运行

```bash
python todofloat.py
```

仅需 Python 3.6+，无第三方依赖（tkinter 随 Python 标准发行版附带）。

## 配置

打开 `todofloat.py`，修改顶部常量：

```python
LARK_CLI = "lark-cli"           # lark-cli 路径
BASE_TOKEN = "Vm4nbpWDlax..."   # 飞书 Base token
TABLE_ID = "tblJvkKfj..."       # 飞书表 ID
WINDOW_ALPHA = 0.95             # 窗口透明度 (0.0 ~ 1.0)
REFRESH_INTERVAL_MS = 300000    # 刷新间隔（毫秒）
```

## 数据源说明

| 数据源 | 存储 | 读写方式 |
|--------|------|----------|
| 飞书待办表 | Lark Base | lark-cli 命令行 |
| 本地待办 | `~/.todofloat/local_todos.json` | 直接读写 JSON |

### 本地待办 JSON 格式

```json
[
  {
    "id": "local_1",
    "content": "写周报",
    "status": "待做",
    "deadline": "",
    "completed": false
  }
]
```

## 依赖

- Python 3.6+（含 tkinter）
- [lark-cli](https://github.com/nicepkg/lark-cli) — 飞书数据源需要（可选）

## 与 macOS 版的区别

| 特性 | macOS 版 | Windows 版 |
|------|----------|------------|
| 语言 | Objective-C | Python |
| UI 框架 | AppKit (NSPanel) | tkinter |
| 窗口效果 | 毛玻璃 (NSVisualEffectView) | 半透明 + 深色背景 |
| 数据源 1 | 苹果提醒事项 (EventKit) | 本地 JSON 文件 |
| 数据源 2 | 飞书待办表 (lark-cli) | 飞书待办表 (lark-cli) |
| 编辑方式 | 行内编辑 | 弹窗编辑 |
| 编译 | clang 编译为 .app | 无需编译，直接运行 |
