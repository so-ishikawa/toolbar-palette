# toolpalette_native.py
#
# 3ds Max環境に依存する層(import pymxs)。
# ここが唯一、3ds Maxのツールバー/アクションテーブル操作に触れる場所。ただし実際のSDK
# 呼び出し(ICustToolbar・IActionManager・MacroButtonData等)は一切ここに書かれておらず、
# すべてネイティブプラグイン(ToolPalette.gup)側のC++で実装されている。ここではその
# ネイティブ関数を pymxs.runtime.ToolPalette.* 経由で呼び出すだけ(.NET経由の実装は
# 使用していない — ToolPalette.gup が3ds Max SDKを直接呼ぶネイティブ実装のため)。

import pymxs

rt = pymxs.runtime


class ToolPaletteBackend:
    """toolpalette_ui.ToolPaletteWindow が期待するbackendインターフェースの実装。"""

    def find_toolbar_at_point(self, x, y):
        hwnd = rt.ToolPaletteAPI.findToolbarAtPoint(x, y)
        return int(hwnd) if hwnd else None

    def place_button(self, button_def, drop_x, drop_y):
        hwnd = self.find_toolbar_at_point(drop_x, drop_y)
        if not hwnd:
            print("[ToolPalette] ツールバー上でドロップされませんでした")
            return False

        if not rt.ToolPaletteAPI.findMacro(button_def.macro_name, button_def.category):
            print(f"[ToolPalette] macroScriptが見つかりません: {button_def.macro_name} / {button_def.category}")
            return False

        tbl_id = rt.ToolPaletteAPI.getLastTblId()
        cmd_id = rt.ToolPaletteAPI.getLastCmdId()

        wd = rt.ToolPaletteAPI.getNativeButtonWidth(hwnd) or 31
        ht = rt.ToolPaletteAPI.getNativeButtonHeight(hwnd) or 30
        pos = rt.ToolPaletteAPI.computeInsertPos(hwnd, drop_x)

        placed = rt.ToolPaletteAPI.placeButton(
            hwnd, tbl_id, cmd_id,
            button_def.label, button_def.tooltip,
            pos, button_def.icon_name, wd, ht,
        )
        if placed:
            rt.ToolPaletteAPI.saveConfig()
            print(f"[ToolPalette] {button_def.label} をツールバーに配置しました")
        return bool(placed)

    def run_macro(self, button_def):
        rt.macros.run(button_def.category, button_def.macro_name)
