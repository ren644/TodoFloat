#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TodoFloat for Windows — 桌面悬浮待办小工具

双数据源：飞书待办表 (lark-cli) + 本地 JSON 文件
功能：勾选完成写回、双击编辑写回、5分钟自动刷新、窗口置顶可拖动

零第三方依赖：tkinter + subprocess + json + os
用法：python todofloat.py
"""

import tkinter as tk
from tkinter import font as tkfont
from tkinter import simpledialog, messagebox
import subprocess
import json
import os
import threading
import time
from datetime import datetime

# ============================================================================
# 配置常量
# ============================================================================

LARK_CLI = "lark-cli"  # lark-cli 路径，如不在 PATH 中请改为完整路径
BASE_TOKEN = "Vm4nbpWDlaxWgWsSQYYcElV7nYf"
TABLE_ID = "tblJvkKfjHDBIBVA"

WINDOW_WIDTH = 340
WINDOW_HEIGHT = 560
WINDOW_ALPHA = 0.95
REFRESH_INTERVAL_MS = 5 * 60 * 1000  # 5 分钟

LOCAL_TODO_DIR = os.path.join(os.path.expanduser("~"), ".todofloat")
LOCAL_TODO_FILE = os.path.join(LOCAL_TODO_DIR, "local_todos.json")

# 颜色主题（深色风格，贴近 macOS 版毛玻璃效果）
BG_COLOR = "#2B2D30"
BG_HEADER = "#33363A"
FG_PRIMARY = "#E8EAED"
FG_SECONDARY = "#9AA0A6"
FG_COMPLETED = "#5F6368"
ACCENT_ORANGE = "#F9AB00"  # 待做
ACCENT_BLUE = "#4FC3F7"    # 进行中
ACCENT_GREEN = "#81C784"   # 已完成
SEPARATOR_COLOR = "#3C4043"
HOVER_COLOR = "#383A3E"
ROW_COLOR = BG_COLOR
BUTTON_BG = "#3C4043"

# ============================================================================
# 数据模型
# ============================================================================

SOURCE_LOCAL = "local"
SOURCE_LARK = "lark"


class TodoItem:
    """单条待办数据。"""

    def __init__(self, source, item_id, content, status="待做",
                 deadline="", completed=False):
        self.source = source        # SOURCE_LOCAL 或 SOURCE_LARK
        self.item_id = item_id      # lark record_id 或本地 uuid
        self.content = content
        self.status = status
        self.deadline = deadline
        self.completed = completed


# ============================================================================
# 本地 JSON 数据源
# ============================================================================

def _ensure_local_dir():
    os.makedirs(LOCAL_TODO_DIR, exist_ok=True)


def load_local_todos():
    """从本地 JSON 文件加载待办。"""
    _ensure_local_dir()
    if not os.path.isfile(LOCAL_TODO_FILE):
        return []
    try:
        with open(LOCAL_TODO_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        items = []
        for d in data:
            items.append(TodoItem(
                source=SOURCE_LOCAL,
                item_id=d.get("id", ""),
                content=d.get("content", ""),
                status=d.get("status", "待做"),
                deadline=d.get("deadline", ""),
                completed=d.get("completed", False),
            ))
        return items
    except (json.JSONDecodeError, KeyError):
        return []


def save_local_todos(items):
    """将本地待办写入 JSON 文件。"""
    _ensure_local_dir()
    data = []
    for it in items:
        if it.source != SOURCE_LOCAL:
            continue
        data.append({
            "id": it.item_id,
            "content": it.content,
            "status": it.status,
            "deadline": it.deadline,
            "completed": it.completed,
        })
    with open(LOCAL_TODO_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _next_local_id():
    """生成简单的自增 ID。"""
    items = load_local_todos()
    max_id = 0
    for it in items:
        try:
            num = int(it.item_id.replace("local_", ""))
            max_id = max(max_id, num)
        except (ValueError, AttributeError):
            pass
    return f"local_{max_id + 1}"


# ============================================================================
# 飞书数据源 (lark-cli)
# ============================================================================

def fetch_lark_todos():
    """通过 lark-cli 拉取飞书待办表数据。"""
    try:
        result = subprocess.run(
            [LARK_CLI, "base", "+record-list",
             "--base-token", BASE_TOKEN,
             "--table-id", TABLE_ID,
             "--limit", "50"],
            capture_output=True, text=True, timeout=30,
            encoding="utf-8",
        )
        if result.returncode != 0:
            print(f"[lark-cli] stderr: {result.stderr.strip()}")
            return []

        data = json.loads(result.stdout)
        if not data.get("ok"):
            print(f"[lark-cli] response not ok: {result.stdout[:200]}")
            return []

        payload = data.get("data", {})
        fields = payload.get("fields", [])
        records = payload.get("data", [])
        record_ids = payload.get("record_id_list", [])

        if not fields or not records:
            return []

        # 字段名 → 索引映射
        field_idx = {name: i for i, name in enumerate(fields)}

        items = []
        for row_i, row in enumerate(records):
            rid = record_ids[row_i] if row_i < len(record_ids) else ""

            def str_at(name):
                idx = field_idx.get(name)
                if idx is None or idx >= len(row):
                    return ""
                val = row[idx]
                return str(val) if val else ""

            content = str_at("待办内容") or "(无内容)"
            status = str_at("状态") or "待做"
            deadline = str_at("截止日期")
            completed = (status == "已完成")

            items.append(TodoItem(
                source=SOURCE_LARK,
                item_id=rid,
                content=content,
                status=status,
                deadline=deadline,
                completed=completed,
            ))

        # 排序：进行中 > 待做 > 已完成，同级按内容排序
        def sort_key(it):
            if it.completed:
                return (2, it.content)
            if it.status == "进行中":
                return (0, it.content)
            return (1, it.content)

        items.sort(key=sort_key)
        return items

    except FileNotFoundError:
        print(f"[lark-cli] 未找到 lark-cli，请确认已安装并在 PATH 中")
        return []
    except subprocess.TimeoutExpired:
        print("[lark-cli] 命令超时")
        return []
    except (json.JSONDecodeError, KeyError) as e:
        print(f"[lark-cli] 解析错误: {e}")
        return []


def complete_lark_todo(item):
    """写回飞书：更新状态。"""
    new_status = "已完成" if item.completed else "待做"
    json_str = json.dumps({"状态": new_status}, ensure_ascii=False)
    try:
        subprocess.run(
            [LARK_CLI, "base", "+record-upsert",
             "--base-token", BASE_TOKEN,
             "--table-id", TABLE_ID,
             "--record-id", item.item_id,
             "--json", json_str],
            capture_output=True, text=True, timeout=15,
            encoding="utf-8",
        )
    except Exception as e:
        print(f"[lark-cli] 更新状态失败: {e}")


def edit_lark_todo(item, new_content):
    """写回飞书：更新内容。"""
    json_str = json.dumps({"待办内容": new_content}, ensure_ascii=False)
    try:
        subprocess.run(
            [LARK_CLI, "base", "+record-upsert",
             "--base-token", BASE_TOKEN,
             "--table-id", TABLE_ID,
             "--record-id", item.item_id,
             "--json", json_str],
            capture_output=True, text=True, timeout=15,
            encoding="utf-8",
        )
    except Exception as e:
        print(f"[lark-cli] 更新内容失败: {e}")


# ============================================================================
# 主界面
# ============================================================================

class TodoFloatApp:
    """TodoFloat Windows 版主应用。"""

    def __init__(self):
        self.root = tk.Tk()
        self.root.title("待办")
        self.root.configure(bg=BG_COLOR)
        self.root.attributes("-topmost", True)
        self.root.attributes("-alpha", WINDOW_ALPHA)

        # 窗口大小和位置（屏幕右上角）
        screen_w = self.root.winfo_screenwidth()
        x = screen_w - WINDOW_WIDTH - 20
        y = 40
        self.root.geometry(f"{WINDOW_WIDTH}x{WINDOW_HEIGHT}+{x}+{y}")
        self.root.minsize(280, 200)
        self.root.resizable(True, True)

        # 深色标题栏（Windows 10+ DWM hack，失败也无所谓）
        self._try_dark_title_bar()

        # 数据
        self.local_items = []
        self.lark_items = []

        # 拖动状态
        self._drag_x = 0
        self._drag_y = 0

        self._build_ui()
        self._schedule_refresh()
        self.refresh()

    # ----------------------------------------------------------------
    # Windows 深色标题栏
    # ----------------------------------------------------------------
    def _try_dark_title_bar(self):
        """尝试通过 DWM 设置深色标题栏（Windows 10 20H1+）。"""
        try:
            import ctypes
            hwnd = ctypes.windll.user32.GetParent(self.root.winfo_id())
            DWMWA_USE_IMMERSIVE_DARK_MODE = 20
            value = ctypes.c_int(1)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE,
                ctypes.byref(value), ctypes.sizeof(value))
        except Exception:
            pass  # 非 Windows 或版本不支持，忽略

    # ----------------------------------------------------------------
    # UI 构建
    # ----------------------------------------------------------------
    def _build_ui(self):
        # ---- 顶部工具栏 ----
        toolbar = tk.Frame(self.root, bg=BG_HEADER, height=36)
        toolbar.pack(fill=tk.X, side=tk.TOP)
        toolbar.pack_propagate(False)

        # 工具栏可拖动窗口
        toolbar.bind("<Button-1>", self._start_drag)
        toolbar.bind("<B1-Motion>", self._on_drag)

        # 标题
        title_lbl = tk.Label(toolbar, text="☑ 待办", font=("Microsoft YaHei UI", 11, "bold"),
                             fg=FG_PRIMARY, bg=BG_HEADER)
        title_lbl.pack(side=tk.LEFT, padx=10)
        title_lbl.bind("<Button-1>", self._start_drag)
        title_lbl.bind("<B1-Motion>", self._on_drag)

        # 加载指示器
        self.status_dot = tk.Label(toolbar, text="", font=("", 8),
                                   fg=ACCENT_GREEN, bg=BG_HEADER)
        self.status_dot.pack(side=tk.RIGHT, padx=(0, 6))

        # 刷新按钮
        refresh_btn = tk.Label(toolbar, text="⟳ 刷新", font=("Microsoft YaHei UI", 9),
                               fg=FG_SECONDARY, bg=BG_HEADER, cursor="hand2")
        refresh_btn.pack(side=tk.RIGHT, padx=(0, 4))
        refresh_btn.bind("<Button-1>", lambda e: self.refresh())
        refresh_btn.bind("<Enter>", lambda e: refresh_btn.config(fg=FG_PRIMARY))
        refresh_btn.bind("<Leave>", lambda e: refresh_btn.config(fg=FG_SECONDARY))

        # 添加本地待办按钮
        add_btn = tk.Label(toolbar, text="＋", font=("Microsoft YaHei UI", 12, "bold"),
                           fg=FG_SECONDARY, bg=BG_HEADER, cursor="hand2")
        add_btn.pack(side=tk.RIGHT, padx=(0, 4))
        add_btn.bind("<Button-1>", lambda e: self._add_local_todo())
        add_btn.bind("<Enter>", lambda e: add_btn.config(fg=FG_PRIMARY))
        add_btn.bind("<Leave>", lambda e: add_btn.config(fg=FG_SECONDARY))

        # ---- 内容区域（可滚动） ----
        container = tk.Frame(self.root, bg=BG_COLOR)
        container.pack(fill=tk.BOTH, expand=True)

        self.canvas = tk.Canvas(container, bg=BG_COLOR, highlightthickness=0,
                                borderwidth=0)
        self.scrollbar = tk.Scrollbar(container, orient=tk.VERTICAL,
                                      command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=self.scrollbar.set)

        self.scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        self.canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        self.scroll_frame = tk.Frame(self.canvas, bg=BG_COLOR)
        self.canvas_window = self.canvas.create_window(
            (0, 0), window=self.scroll_frame, anchor=tk.NW)

        self.scroll_frame.bind("<Configure>", self._on_frame_configure)
        self.canvas.bind("<Configure>", self._on_canvas_configure)

        # 鼠标滚轮
        self.canvas.bind_all("<MouseWheel>", self._on_mousewheel)

        # ---- 底部状态栏 ----
        self.footer = tk.Label(self.root, text="", font=("Microsoft YaHei UI", 8),
                               fg=FG_SECONDARY, bg=BG_HEADER, anchor=tk.CENTER,
                               padx=6, pady=3)
        self.footer.pack(fill=tk.X, side=tk.BOTTOM)

    # ----------------------------------------------------------------
    # 滚动与拖动
    # ----------------------------------------------------------------
    def _on_frame_configure(self, _event=None):
        self.canvas.configure(scrollregion=self.canvas.bbox("all"))

    def _on_canvas_configure(self, event):
        self.canvas.itemconfig(self.canvas_window, width=event.width)

    def _on_mousewheel(self, event):
        self.canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

    def _start_drag(self, event):
        self._drag_x = event.x_root - self.root.winfo_x()
        self._drag_y = event.y_root - self.root.winfo_y()

    def _on_drag(self, event):
        x = event.x_root - self._drag_x
        y = event.y_root - self._drag_y
        self.root.geometry(f"+{x}+{y}")

    # ----------------------------------------------------------------
    # 刷新逻辑
    # ----------------------------------------------------------------
    def _schedule_refresh(self):
        self.root.after(REFRESH_INTERVAL_MS, self._auto_refresh)

    def _auto_refresh(self):
        self.refresh()
        self._schedule_refresh()

    def refresh(self):
        """拉取数据并重建 UI。"""
        self.status_dot.config(text="⏳", fg=ACCENT_ORANGE)
        self.root.update_idletasks()

        def _do_fetch():
            local = load_local_todos()
            lark = fetch_lark_todos()
            self.root.after(0, lambda: self._on_data_loaded(local, lark))

        threading.Thread(target=_do_fetch, daemon=True).start()

    def _on_data_loaded(self, local, lark):
        self.local_items = local
        self.lark_items = lark
        self._rebuild_list()
        now = datetime.now().strftime("%H:%M:%S")
        self.footer.config(text=f"更新于 {now} · 双击编辑 · 5分钟自动刷新")
        self.status_dot.config(text="●", fg=ACCENT_GREEN)

    # ----------------------------------------------------------------
    # 列表重建
    # ----------------------------------------------------------------
    def _rebuild_list(self):
        """清空并重绘所有待办行。"""
        for widget in self.scroll_frame.winfo_children():
            widget.destroy()

        row_index = 0

        # ---- 本地待办区 ----
        row_index = self._add_section_header(
            "📋  本地待办", len(self.local_items), row_index)

        if not self.local_items:
            row_index = self._add_empty_hint(
                "暂无本地待办 · 点击 ＋ 添加", row_index)
        else:
            for item in self.local_items:
                row_index = self._add_todo_row(item, row_index)

        # ---- 分隔线 ----
        row_index = self._add_separator(row_index)

        # ---- 飞书待办区 ----
        row_index = self._add_section_header(
            "📅  飞书待办", len(self.lark_items), row_index)

        if not self.lark_items:
            row_index = self._add_empty_hint(
                "暂无飞书待办（请确认 lark-cli 已配置）", row_index)
        else:
            for item in self.lark_items:
                row_index = self._add_todo_row(item, row_index)

    def _add_section_header(self, title, count, row_index):
        """添加分区标题。"""
        frame = tk.Frame(self.scroll_frame, bg=BG_COLOR)
        frame.pack(fill=tk.X, padx=0, pady=(8, 2))

        text = f"{title} ({count})"
        lbl = tk.Label(frame, text=text, font=("Microsoft YaHei UI", 10, "bold"),
                       fg=FG_SECONDARY, bg=BG_COLOR, anchor=tk.W)
        lbl.pack(fill=tk.X, padx=14)
        return row_index + 1

    def _add_empty_hint(self, text, row_index):
        """添加空状态提示。"""
        lbl = tk.Label(self.scroll_frame, text=text,
                       font=("Microsoft YaHei UI", 9),
                       fg=FG_SECONDARY, bg=BG_COLOR, anchor=tk.W)
        lbl.pack(fill=tk.X, padx=14, pady=(2, 4))
        return row_index + 1

    def _add_separator(self, row_index):
        """添加分隔线。"""
        sep = tk.Frame(self.scroll_frame, bg=SEPARATOR_COLOR, height=1)
        sep.pack(fill=tk.X, padx=10, pady=6)
        return row_index + 1

    def _add_todo_row(self, item, row_index):
        """添加单条待办行。"""
        row = tk.Frame(self.scroll_frame, bg=ROW_COLOR, padx=6, pady=3)
        row.pack(fill=tk.X, padx=4, pady=1)

        # 状态颜色圆点
        dot_color = self._status_color(item)
        dot = tk.Label(row, text="●", font=("", 7), fg=dot_color, bg=ROW_COLOR)
        dot.pack(side=tk.LEFT, padx=(6, 0))

        # Checkbox
        var = tk.BooleanVar(value=item.completed)
        cb = tk.Checkbutton(
            row, variable=var, bg=ROW_COLOR, activebackground=ROW_COLOR,
            selectcolor=BG_COLOR, highlightthickness=0, bd=0,
            command=lambda it=item, v=var, d=dot: self._on_toggle(it, v, d))
        cb.pack(side=tk.LEFT, padx=(2, 4))

        # 内容文本
        content_text = item.content
        fg_color = FG_COMPLETED if item.completed else FG_PRIMARY
        content_font = ("Microsoft YaHei UI", 10)
        if item.completed:
            content_text = self._strikethrough(content_text)

        content_lbl = tk.Label(
            row, text=content_text, font=content_font,
            fg=fg_color, bg=ROW_COLOR, anchor=tk.W,
            wraplength=180, justify=tk.LEFT)
        content_lbl.pack(side=tk.LEFT, fill=tk.X, expand=True)

        # 截止日期
        if item.deadline:
            date_lbl = tk.Label(row, text=item.deadline,
                                font=("Microsoft YaHei UI", 8),
                                fg=FG_SECONDARY, bg=ROW_COLOR)
            date_lbl.pack(side=tk.RIGHT, padx=(4, 6))

        # 双击编辑
        if not item.completed:
            content_lbl.bind("<Double-Button-1>",
                             lambda e, it=item: self._on_edit(it))

        # 悬浮高亮
        for w in (row, content_lbl, dot, cb):
            w.bind("<Enter>", lambda e, r=row: self._row_hover(r, True))
            w.bind("<Leave>", lambda e, r=row: self._row_hover(r, False))

        return row_index + 1

    # ----------------------------------------------------------------
    # 交互回调
    # ----------------------------------------------------------------
    def _on_toggle(self, item, var, dot_label):
        """勾选/取消勾选待办。"""
        item.completed = var.get()
        item.status = "已完成" if item.completed else "待做"

        # 更新圆点颜色
        dot_label.config(fg=self._status_color(item))

        # 写回数据源（后台线程）
        if item.source == SOURCE_LOCAL:
            # 更新内存中的本地列表并保存
            for it in self.local_items:
                if it.item_id == item.item_id:
                    it.completed = item.completed
                    it.status = item.status
            save_local_todos(self.local_items)
        elif item.source == SOURCE_LARK:
            threading.Thread(target=complete_lark_todo, args=(item,),
                             daemon=True).start()

        # 重绘
        self._rebuild_list()

    def _on_edit(self, item):
        """双击编辑待办内容。"""
        new_content = simpledialog.askstring(
            "编辑待办", "修改内容：",
            initialvalue=item.content,
            parent=self.root)

        if new_content and new_content.strip() and new_content != item.content:
            new_content = new_content.strip()
            item.content = new_content

            if item.source == SOURCE_LOCAL:
                for it in self.local_items:
                    if it.item_id == item.item_id:
                        it.content = new_content
                save_local_todos(self.local_items)
            elif item.source == SOURCE_LARK:
                threading.Thread(target=edit_lark_todo,
                                 args=(item, new_content),
                                 daemon=True).start()

            self._rebuild_list()

    def _add_local_todo(self):
        """弹窗添加一条本地待办。"""
        content = simpledialog.askstring(
            "新建待办", "待办内容：", parent=self.root)

        if content and content.strip():
            new_id = _next_local_id()
            item = TodoItem(
                source=SOURCE_LOCAL,
                item_id=new_id,
                content=content.strip(),
                status="待做",
                completed=False,
            )
            self.local_items.append(item)
            save_local_todos(self.local_items)
            self._rebuild_list()

    # ----------------------------------------------------------------
    # 辅助方法
    # ----------------------------------------------------------------
    @staticmethod
    def _status_color(item):
        if item.completed or item.status == "已完成":
            return ACCENT_GREEN
        if item.status == "进行中":
            return ACCENT_BLUE
        return ACCENT_ORANGE

    @staticmethod
    def _strikethrough(text):
        """用 Unicode 组合删除线模拟删除效果。"""
        return "".join(c + "\u0336" for c in text)

    @staticmethod
    def _row_hover(row, enter):
        color = HOVER_COLOR if enter else ROW_COLOR
        row.config(bg=color)
        for child in row.winfo_children():
            try:
                child.config(bg=color)
            except tk.TclError:
                pass

    # ----------------------------------------------------------------
    # 启动
    # ----------------------------------------------------------------
    def run(self):
        self.root.mainloop()


# ============================================================================
# 入口
# ============================================================================

if __name__ == "__main__":
    app = TodoFloatApp()
    app.run()
