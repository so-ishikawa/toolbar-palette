-- ToolPalette_Config.ms
-- Tool Paletteに表示するボタンの定義リスト。
-- 自分のmacroScriptを追加したい場合は、下の配列に1行足すだけでよい。
-- macroName / category は対象macroScriptの `macroScript <macroName> category:"<category>"` の値と一致させること。
-- iconName は Qtリソース(toolbar-palette\qtres\toolpalette.rcc)に登録済みのエイリアス名
-- (拡張子・":/"なし)。実行時に ":/<iconName>" として MacroButtonData.IconName_ に渡される。
-- 新しいアイコンを追加する場合は qtres\toolpalette.qrc にエントリを足して rcc を再コンパイルすること。
-- iconPath はパレットUI(.NET)上のボタン画像として読み込むファイルパス(表示専用、書き込みは発生しない)。
-- id はツールバー配置時に使う固定コントロールID。ToolPalette_Placements.txtでの永続化と
-- 起動時の再配置(ToolPalette_ReconcileOnStartup)で、このボタンを一意に識別するために使う。
-- 新規追加時は既存と重複しない値を割り振ること。

struct ToolPalette_ButtonDef (
	macroName,
	category,
	label,
	tooltip,
	iconName, -- Qtリソースのエイリアス名(拡張子・":/"なし)。ツールバー配置時に使う
	iconPath, -- パレットUI用のアイコン画像ファイル(.png)フルパス
	id        -- 固定コントロールID(重複禁止)。再起動後の自動再配置で使う
)

global ToolPalette_IconDir = @"C:\Program Files\Autodesk\3ds Max 2027\UI_ln\Resources\Light\Icons\Main\"

global ToolPalette_Config = #(
	ToolPalette_ButtonDef \
		macroName:"ToolPalette_ToggleFreeze" category:"ToolPalette Samples" \
		label:"Freeze" tooltip:"選択オブジェクトのフリーズ状態を切り替える" \
		iconName:"ToolPaletteIcons/ToolPaletteFreeze" \
		iconPath:(ToolPalette_IconDir + "Freeze Selection - 000000E0_00000000 - 32.png") \
		id:60001,
	ToolPalette_ButtonDef \
		macroName:"ToolPalette_RedrawViewports" category:"ToolPalette Samples" \
		label:"Redraw" tooltip:"全ビューポートを強制再描画する" \
		iconName:"ToolPaletteIcons/ToolPaletteRedraw" \
		iconPath:(ToolPalette_IconDir + "TogglexViewAutoUpdate_32.png") \
		id:60002,
	ToolPalette_ButtonDef \
		macroName:"ToolPalette_ShowSelectionInfo" category:"ToolPalette Samples" \
		label:"Sel Info" tooltip:"現在の選択数を表示する" \
		iconName:"ToolPaletteIcons/ToolPaletteSelInfo" \
		iconPath:(ToolPalette_IconDir + "EditSelectedObject_sMaterial_32.png") \
		id:60003
)
