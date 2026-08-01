-- ToolPalette_Tools.ms
-- Tool Paletteからドラッグしてツールバーに配置するための動作確認用サンプルmacroScript群。
-- 実運用では、ここに書かず既存のmacroScriptをそのまま流用し、
-- ToolPalette_Config.ms 側でそのmacroName/categoryを参照すればよい。

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
	on execute do
	(
		completeRedraw()
	)
)

macroScript ToolPalette_ShowSelectionInfo
	category:"ToolPalette Samples"
	buttonText:"Selection Info"
	toolTip:"現在の選択数を表示する"
(
	on execute do
	(
		format "ToolPalette Samples: %個のオブジェクトを選択中\n" selection.count
		messageBox (selection.count as string + " 個のオブジェクトを選択中") title:"Selection Info"
	)
)
