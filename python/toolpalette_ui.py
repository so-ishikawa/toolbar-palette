# toolpalette_ui.py
#
# パレットUI本体。純粋なPython(PySide6のみ) — pymxs・3ds Max固有APIへの依存は一切ない。
# 実際に3ds Maxのツールバーへボタンを配置する処理は一切知らず、backendオブジェクト
# (toolpalette_native.ToolPaletteBackend、または任意のダックタイピング互換オブジェクト)に
# 委譲する。これにより、UIのロジックと3ds Max依存処理を完全に分離している。
#
# 2026-07-31 追記: 当初は grabMouse() + 自前の最上位ウィンドウ(ゴースト表示用)を
# 手動で追従させる実装だったが、実機でドラッグ中に3ds Max全体がハングする事故が発生した
# (Windowsイベントログで Event ID 1002 "Application Hang" を確認)。マウスを掴んだ状態のまま
# 別の最上位ウィンドウを新規生成するのはWindows上のQtで不安定になりやすい既知のパターンのため、
# Qt標準のドラッグ&ドロップ機構(QDrag)に置き換えた。QDragはドラッグ中のプレビュー表示も
# Qt自身が面倒を見るため、自前のゴーストウィンドウ(_GhostWidget)は不要になった。

import os

from PySide6 import QtCore, QtGui, QtWidgets

_DRAG_THRESHOLD = 6  # px


class _DragButton(QtWidgets.QToolButton):
    """パレット上の1個のボタン。クリックではmacroを実行し、ドラッグ(QDrag)ではツールバーへの
    配置をpalette_windowに依頼する。"""

    def __init__(self, button_def, palette_window):
        super().__init__()
        self.button_def = button_def
        self._palette_window = palette_window
        self._press_pos = None

        self.setFixedSize(56, 56)
        self.setText(button_def.label)
        self.setToolTip(button_def.tooltip)
        self.setToolButtonStyle(QtCore.Qt.ToolButtonTextUnderIcon)
        if button_def.icon_path and os.path.exists(button_def.icon_path):
            self.setIcon(QtGui.QIcon(button_def.icon_path))
            self.setIconSize(QtCore.QSize(28, 28))

    def mousePressEvent(self, event):
        if event.button() == QtCore.Qt.LeftButton:
            self._press_pos = event.position().toPoint()
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self._press_pos is not None and (event.buttons() & QtCore.Qt.LeftButton):
            delta = event.position().toPoint() - self._press_pos
            if delta.manhattanLength() > _DRAG_THRESHOLD:
                self._start_drag()
                return
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        # QDragが起動していればQt側がこのイベントを消費するため、ここに来るのは
        # 「しきい値未満で離した = ドラッグではなく通常のクリック」の場合のみ。
        if self._press_pos is not None:
            self._press_pos = None
            self._palette_window.handle_click(self.button_def)
        super().mouseReleaseEvent(event)

    def _start_drag(self):
        self._press_pos = None
        drag = QtGui.QDrag(self)
        mime = QtCore.QMimeData()
        # 2026-07-31 追記: ここで mime.setText(...) (= "text/plain") を使うと、
        # 3ds Max純正のツールバー自身が持つドロップ受理処理(カスタマイズUI等からの
        # アクションドラッグ機能)がこのテキストを検知し、無関係な汎用ボタンを勝手に
        # 追加してしまう事故が実機で発生した(1回のドラッグでボタンが2個登録される)。
        # 3ds Max純正が認識しないであろう専用フォーマットだけを設定することで、
        # 純正側のドロップ処理を素通りさせ、こちら側(exec()後のカーソル位置判定)だけが
        # 反応するようにする。
        mime.setData("application/x-toolpalette-buttonref", self.button_def.macro_name.encode("utf-8"))
        drag.setMimeData(mime)
        if not self.icon().isNull():
            drag.setPixmap(self.icon().pixmap(28, 28))
        drag.exec(QtCore.Qt.CopyAction)
        # QAbstractButton(QToolButtonの親クラス)は「押されている(down)」という内部状態を
        # 自前で保持しており、通常はmouseReleaseEventで解除される。ドラッグ開始後は
        # OS/Qtのドラッグ機構がマウスイベントを奪ってしまい、このボタンには正式な
        # mouseReleaseEventが届かないため、down状態が解除されずボタンが青い(押下)ままに
        # なる不具合が実機で発生した。exec()から戻った時点(ドロップ/キャンセル確定後)で
        # 明示的に解除する。
        self.setDown(False)
        # exec()はドロップ(またはキャンセル)されるまでブロックし、戻ってきた時点で
        # マウスは既に離されている。ドロップ先は3ds Maxのネイティブツールバー(非Qt-drop-aware)
        # なので、Qt形式のドロップ受理は期待せず、カーソルの最終位置で自前の配置処理を行う。
        global_pos = QtGui.QCursor.pos()
        self._palette_window.handle_drop(self.button_def, global_pos.x(), global_pos.y())


class ToolPaletteWindow(QtWidgets.QWidget):
    """フローティングのTool Paletteウィンドウ。

    backend には以下のメソッドを持つオブジェクトを渡す(ダックタイピング):
        place_button(button_def, drop_x, drop_y) -> bool
        run_macro(button_def) -> None
    """

    def __init__(self, buttons, backend, columns=2, parent=None):
        super().__init__(parent, QtCore.Qt.Tool | QtCore.Qt.WindowStaysOnTopHint)
        self.backend = backend

        self.setWindowTitle("Tool Palette")
        layout = QtWidgets.QGridLayout(self)
        layout.setSpacing(4)
        for i, button_def in enumerate(buttons):
            btn = _DragButton(button_def, self)
            layout.addWidget(btn, i // columns, i % columns)
        self.resize(180, 160)

    # ── クリック / ドロップのハンドリング ────────────────────────
    def handle_click(self, button_def):
        try:
            self.backend.run_macro(button_def)
        except Exception as exc:  # noqa: BLE001 - パレットUIをクラッシュさせない
            print(f"[ToolPalette] run_macro failed: {exc}")

    def handle_drop(self, button_def, x, y):
        try:
            placed = self.backend.place_button(button_def, x, y)
            if not placed:
                print(f"[ToolPalette] ツールバー上でドロップされませんでした、または配置に失敗しました: {button_def.label}")
        except Exception as exc:  # noqa: BLE001
            print(f"[ToolPalette] place_button failed: {exc}")
