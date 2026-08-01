# toolpalette_macros.py
#
# 3ds Max環境に依存する層(import pymxs)。
#
# macroScript構文はMAXScript言語そのものの機能であり、Pythonから直接「定義」する
# 手段は存在しない(3ds MaxのPython統合は、この部分をバイパスできるようにはなっていない)。
# そのため、ここでは .ms ファイルを一切ディスクに置かず、pymxs.runtime.execute() で
# MAXScriptのmacroScript定義を文字列として実行する形を取っている。
#
# 自分の既存macroScriptに差し替える場合は、register_sample_macros() を呼ばず、
# toolpalette_config.py の macro_name / category を自分のマクロの値に変更するだけでよい。

import pymxs

rt = pymxs.runtime

_SAMPLE_MACROS_MXS = r"""
macroScript ToolPalette_ToggleFreeze
    category:"ToolPalette Samples"
    buttonText:"Freeze Toggle"
    toolTip:"選択オブジェクトのフリーズ状態を切り替える"
(
    on execute do
    (
        if selection.count == 0 then
        (
            messageBox "オブジェクトを選択してください。" title:"ToolPalette Samples"
        )
        else
        (
            undo "ToolPalette Freeze Toggle" on
            (
                for obj in selection do obj.isFrozen = not obj.isFrozen
            )
        )
    )
)

macroScript ToolPalette_RedrawViewports
    category:"ToolPalette Samples"
    buttonText:"Redraw Viewports"
    toolTip:"全ビューポートを強制再描画する"
(
    on execute do completeRedraw()
)

macroScript ToolPalette_ShowSelectionInfo
    category:"ToolPalette Samples"
    buttonText:"Selection Info"
    toolTip:"現在の選択数を表示する"
(
    on execute do messageBox ((selection.count as string) + " 個のオブジェクトを選択中") title:"Selection Info"
)
"""

# パレットを開くためのランチャーmacro。ツールバー・メニュー・キーボードショートカットに
# 割り当てられるよう、通常のmacroScriptとして登録する(実体はPython関数の呼び出しだけ)。
_OPEN_MACRO_MXS = r"""
macroScript ToolPalette_Open
    category:"ToolPalette"
    buttonText:"Tool Palette"
    toolTip:"Open Tool Palette (drag buttons onto a toolbar to install them)"
(
    on execute do
    (
        local tb = python.import "toolpalette_bootstrap"
        tb.show_window()
    )
)
"""


def register_sample_macros():
    rt.execute(_SAMPLE_MACROS_MXS)


def register_open_macro():
    rt.execute(_OPEN_MACRO_MXS)
