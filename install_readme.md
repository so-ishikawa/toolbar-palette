# Tool Palette (ドラッグでツールバー配置)

**バージョン: 2.0** (2026-07-31。.NET不使用・MAXScriptファイル不使用の全面書き換え版)

## v2.0の設計方針

- **`.NET`(`Autodesk.Max`アセンブリ)を一切使用しない。** ツールバー/アクションテーブル操作は
  すべて3ds Max SDKのネイティブC++クラス(`ICustToolbar`・`IActionManager`・`ActionItem`・
  `MacroEntry`・`MacroButtonData`・`ToolMacroItem`・`CUIFrameMgr`)を直接呼ぶ。
- **`.ms`(MAXScript)ファイルを1つも使わない。** パレットUI・設定・配置ロジックはすべてPython。
  macroScript構文(3ds Max側の制約で避けられない)は、`.ms`ファイルとしてではなく、
  Python文字列としてpymxs経由で動的に登録する。
- **Pythonは「純粋なPython」と「pymxs依存(3ds Max環境依存)」の層に分離。**

## ファイル構成

```
toolbar-palette/
  ToolPalette.gup          -- ネイティブプラグイン本体(唯一の非Pythonコード)
  python/
    toolpalette_config.py    -- 純粋なPython(ボタン定義データ、pymxs不使用)
    toolpalette_ui.py        -- 純粋なPython(PySide6のパレットUI、pymxs不使用)
    toolpalette_native.py    -- pymxs依存(ToolPalette.gupのFPInterfaceを呼ぶだけ)
    toolpalette_macros.py    -- pymxs依存(サンプルmacroScriptを動的登録)
    toolpalette_bootstrap.py -- エントリポイント(上記を結線するだけの薄い層)
  qtres/
    toolpalette.qrc / .rcc  -- ツールバーアイコン用Qtリソース
  native/
    src/toolpalette_plugin.cpp -- ToolPalette.gupのC++ソース
    CMakeLists.txt
  install_readme.md          -- このファイル
  _legacy_v1_ms_backup/       -- v1.x時代の.msファイル一式(参考保存、未使用)
```

## 実装方式

### ネイティブプラグイン(`ToolPalette.gup`)

`native/src/toolpalette_plugin.cpp` 1ファイルで完結。3dsmax-mcp(MCPブリッジ)への依存はない。

1. **起動タイミング処理**(`LibInitialize`・`NOTIFY_TOOLBARS_PRE_LOAD`・`NOTIFY_CUI_MENUS_PRE_LOAD`・
   `NOTIFY_SYSTEM_STARTUP`): Qtアイコンリソースの早期登録、起動完了後の`RefreshAllToolbarIcons`
   (`ICustToolbar::ResetIconImages()`一括呼び出し)、そして**`python.executeFile`を1行呼んで
   Pythonブートストラップを起動する**。これがMAXScriptとの唯一の接点。
2. **`ToolPaletteAPI` という名前の `FPStaticInterface`** を公開し、`pymxs.runtime.ToolPaletteAPI.*`
   として以下の関数がPythonから直接呼べる(.NETラッパーは一切経由しない、SDKネイティブ呼び出し):
   - `getMaxHwnd()` — 3ds Maxメインウィンドウのhwnd
   - `findMacro(macroName, category)` / `getLastTblId()` / `getLastCmdId()` — ActionManagerの
     「マクロ スクリプト」テーブルからmacroScriptのtblId/cmdIdを検索(`IActionManager`・
     `ActionTable::GetActionByIndex`・`ActionItem::GetMacroScript`・`MacroEntry::GetName/GetCategory`)
   - `getNativeButtonWidth(hwnd)` / `getNativeButtonHeight(hwnd)` — 配置先ツールバー上の純正
     `CustButton`を実測してサイズを合わせる
   - `computeInsertPos(hwnd, dropX)` — ドロップ位置に応じた挿入インデックスの計算
   - `placeButton(hwnd, tblId, cmdId, label, tooltip, pos, iconName, wd, ht)` — `MacroButtonData`+
     `ToolMacroItem`+`ICustToolbar::AddTool`でボタンを実配置
   - `saveConfig()` — `CUIFrameMgr::WriteConfig()`(`cui.SaveConfig()`のネイティブ相当)
   - `findToolbarAtPoint(x, y)` — スクリーン座標からドロップ先ツールバーのhwndを特定

   **重要な実装上の注意:** FPStaticInterfaceの登録名(`ToolPaletteAPI`)は、GUPのClassDesc名
   (`ToolPalette`)と**同じ名前にしてはいけない**。同名にすると、3ds Maxが自動公開する
   GUPインスタンス自身(`classOf` = `GlobalUtilityPlugin`)が同名のグローバルとして先に解決され、
   FPInterfaceの関数群が一切呼べなくなる(実機で発生・確認済みの罠)。

### Python層

- **`toolpalette_config.py`(純粋)**: `ButtonDef`のリスト。macro_name/category/label/tooltip/
  icon_name/icon_pathを持つだけのデータ。
- **`toolpalette_ui.py`(純粋、PySide6のみ)**: `ToolPaletteWindow`・`_DragButton`(`QToolButton`
  ベース)・`_GhostWidget`。ドラッグ検出(`grabMouse`+しきい値6px)・ゴースト表示・クリック/ドロップの
  ハンドリングを行うが、実際の3ds Max操作は`backend`オブジェクト(ダックタイピング)に委譲する。
- **`toolpalette_native.py`(pymxs依存)**: `ToolPaletteBackend`。`toolpalette_ui`が要求する
  `place_button`/`run_macro`インターフェースを、`pymxs.runtime.ToolPaletteAPI.*`呼び出しで実装する。
- **`toolpalette_macros.py`(pymxs依存)**: サンプルmacroScript(Freeze/Redraw/SelInfo)と、
  パレットを開くランチャーmacro(`ToolPalette_Open`、カテゴリ`ToolPalette`)を、
  `pymxs.runtime.execute()`でMAXScript文字列として動的登録する。**`.ms`ファイルは一切使わない。**
  自分の既存macroScriptに差し替える場合は、`register_sample_macros()`を呼ぶのをやめ、
  `toolpalette_config.py`のmacro_name/categoryを自分のマクロの値に変更するだけでよい。
- **`toolpalette_bootstrap.py`**: 上記を結線するだけの薄いエントリポイント。
  `python.executeFile`で1回だけ実行される。

## 導入手順

1. `toolbar-palette`フォルダごと好きな場所にコピーする。
2. 3ds Maxの「サードパーティ製プラグイン」パスにこのフォルダを追加する(または中身を
   3ds Maxの`plugins`フォルダに直接コピーする)。
3. 3ds Maxを再起動する。リスナーに「[ToolPalette] Python bootstrap loaded. ...」と出れば成功。
4. 「ToolPalette」カテゴリの「Tool Palette」マクロを実行するとパレットが開く
   (`macros.run "ToolPalette" "ToolPalette_Open"`、またはツールバー/キーボードショートカットに
   割り当てて呼び出す)。

## 既知の制約(v2.0時点)

- ドロップ位置による挿入順の計算・ツールバー自動検出のロジックはv1系から踏襲しており、
  複雑なレイアウトでは厳密でない場合がある。
- `getNativeButtonWidth`/`getNativeButtonHeight`はこの環境での実測値であり、異なるDPI環境での
  検証は未実施。
- `FPStaticInterface`のPython向け引数はプリミティブ型(文字列・整数・真偽値)のみに限定しており、
  複数値をまとめて返す必要がある場面(macro検索結果のtblId/cmdId)は、`findMacro()`で内部状態に
  保存してから`getLastTblId()`/`getLastCmdId()`で個別に取得する設計にしている。

## 変更履歴

- **v2.0 (2026-07-31)**: 全面書き換え。.NET不使用・.msファイル不使用(サンプルmacroScriptも
  Python文字列として動的登録)に変更。パレットUIをPySide6に移行。ネイティブ側は
  `FPStaticInterface`(`ToolPaletteAPI`)としてpymxsに関数群を公開する設計に変更。
- **v1.1 (2026-07-31)**: MCPブリッジ(3dsmax-mcp)から完全に分離。専用の独立ネイティブプラグイン
  `ToolPalette.gup`を新設。
- **v1.0 (2026-07-31)**: 初の安定版(MAXScript + .NET実装)。クリック無反応・アイコン空白化・
  自動ロード失敗・ボタンサイズ不一致をすべて解決。
