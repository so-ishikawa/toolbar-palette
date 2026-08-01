# toolpalette_config.py
#
# ボタン定義データ。純粋なPython — 3ds Max / pymxsへの依存は一切ない。
# 旧 ToolPalette_Config.ms の後継。自分の既存macroScriptに差し替える場合は、
# BUTTONS配列に ButtonDef を1つ追加するだけでよい(macro_name/categoryは対象
# macroScript定義の値と一致させること)。

import os

# パレットUI(ボタンのアイコン表示専用)で使う純正アイコンのフォルダ。
# 実際にツールバーへ配置されるアイコンは qtres/toolpalette.rcc 側(icon_name)を使う。
_ICON_DIR = r"C:\Program Files\Autodesk\3ds Max 2027\UI_ln\Resources\Light\Icons\Main"


class ButtonDef:
    def __init__(self, macro_name, category, label, tooltip, icon_name, icon_path=None, button_id=None):
        self.macro_name = macro_name
        self.category = category
        self.label = label
        self.tooltip = tooltip
        self.icon_name = icon_name  # Qtリソースのエイリアス名(拡張子・":/"なし)
        self.icon_path = icon_path  # パレットUI表示用の画像ファイル(.png)フルパス
        self.button_id = button_id


BUTTONS = [
    ButtonDef(
        macro_name="ToolPalette_ToggleFreeze",
        category="ToolPalette Samples",
        label="Freeze",
        tooltip="選択オブジェクトのフリーズ状態を切り替える",
        icon_name="ToolPaletteIcons/ToolPaletteFreeze",
        icon_path=os.path.join(_ICON_DIR, "Freeze Selection - 000000E0_00000000 - 32.png"),
        button_id=60001,
    ),
    ButtonDef(
        macro_name="ToolPalette_RedrawViewports",
        category="ToolPalette Samples",
        label="Redraw",
        tooltip="全ビューポートを強制再描画する",
        icon_name="ToolPaletteIcons/ToolPaletteRedraw",
        icon_path=os.path.join(_ICON_DIR, "TogglexViewAutoUpdate_32.png"),
        button_id=60002,
    ),
    ButtonDef(
        macro_name="ToolPalette_ShowSelectionInfo",
        category="ToolPalette Samples",
        label="Sel Info",
        tooltip="現在の選択数を表示する",
        icon_name="ToolPaletteIcons/ToolPaletteSelInfo",
        icon_path=os.path.join(_ICON_DIR, "EditSelectedObject_sMaterial_32.png"),
        button_id=60003,
    ),
]
