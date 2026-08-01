# toolpalette_bootstrap.py
#
# エントリポイント。ネイティブプラグイン(native/src/toolpalette_plugin.cpp)が
# NOTIFY_SYSTEM_STARTUP時に `python.executeFile` で1回だけ実行する
# (MAXScriptとの接点はこの1行のみ)。
#
# 「純粋なPython」レイヤ(toolpalette_ui / toolpalette_config)と
# 「pymxs依存」レイヤ(toolpalette_native / toolpalette_macros)を組み合わせるだけの薄い層。

import os
import sys

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

import toolpalette_config      # 純粋なPython
import toolpalette_ui          # 純粋なPython(PySide6のみ)
import toolpalette_native      # pymxs依存
import toolpalette_macros      # pymxs依存

from PySide6 import QtWidgets

_window = None


def show_window():
    """Tool Paletteウィンドウを開く(既に開いていれば前面に出す)。"""
    global _window
    app = QtWidgets.QApplication.instance()
    if app is None:
        # 3ds Max内で実行される限り、通常はここに来ない(3ds Max自身がQApplicationを
        # 持っている)。念のためのフォールバック。
        app = QtWidgets.QApplication([])
    # QApplication.quitOnLastWindowClosed のデフォルトはTrue。パレットのウィンドウを
    # 閉じた際に「最後のトップレベルウィンドウが閉じられた」と判定され、3ds Max本体が
    # 使っている同一QApplicationインスタンスに対して意図せずquit()が呼ばれる可能性がある
    # ため、明示的に無効化しておく(実機で「一度閉じると二度と開けなくなる」不具合の原因
    # として疑われたための対策)。
    app.setQuitOnLastWindowClosed(False)
    # closeイベント後もPythonオブジェクト自体は残るが、ネイティブ側のウィンドウリソースは
    # 破棄されている可能性があるため、isVisible()がFalseなら安全のため作り直す。
    if _window is None or not _window.isVisible():
        backend = toolpalette_native.ToolPaletteBackend()
        _window = toolpalette_ui.ToolPaletteWindow(toolpalette_config.BUTTONS, backend)
    _window.show()
    _window.raise_()
    _window.activateWindow()


toolpalette_macros.register_sample_macros()
toolpalette_macros.register_open_macro()
print("[ToolPalette] Python bootstrap loaded. 'Tool Palette' macro (category: ToolPalette) is ready.")
