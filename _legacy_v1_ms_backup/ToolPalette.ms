-- ToolPalette.ms
--
-- 独自のフローティングパレット上のボタンをドラッグし、3ds Max純正の既存ツールバー
-- (メインツールバー等)にドロップすると、対応するmacroScriptを実際のツールバーへ
-- 恒久的に配置する(cui.SaveConfig()でワークスペース(.cuix)に保存され、
-- Max再起動後も保持される)。
--
-- 前提: ToolPalette_Tools.ms と ToolPalette_Config.ms を先にfileInしてあること。
--
-- 重要な設計変更(2027版で実機検証して判明した内容):
--   3ds Max 2027ではUIがQtベースに刷新されており、MAXScriptレベルの`menuMan`
--   グローバルは存在しない(windows/actionMan/macros/新設のcui構造体は健在)。
--   ただしツールバーの実ウィンドウは今もクラス名 "CustToolbar" のネイティブ
--   コントロールとして存在し、3ds Maxが同梱する管理アセンブリ "Autodesk.Max"
--   (.NET SDKラッパー)経由で当時のICustToolbar/ActionManager SDKに到達できる。
--   実機で以下を確認済み:
--     - dotNet.loadAssembly "Autodesk.Max" でロード可能
--     - (dotNetClass "Autodesk.Max.GlobalInterface").Instance がSDKの入口
--     - gi.GetICustToolbar <hwnd> で対象ツールバーの ICustToolbar が取得できる
--     - macroScriptは ActionManager のテーブル(名称:"マクロ スクリプト")に
--       全件格納されている。各アイテムの .MacroScript.Name / .Category を
--       比較すれば目的のmacroScriptのcmdId(テーブル内インデックス)が求まる
--     - gi.MacroButtonData.Create cmdId label tooltip -1 "" で IMacroButtonData を作り
--       gi.ToolMacroItem.Create 24 24 mbd 0 で IToolMacroItem を作り
--       toolbar.AddTool tmi -1 で実際にツールバー末尾へボタンが追加される
--       (実機でNumItemsが11→12に増えることを確認、DeleteToolsで削除も確認済み)
--     - cui.SaveConfig() で現在のワークスペース(.cuix)に保存される
--
-- 見た目のドラッグは.NET(Windows Forms)側で自前実装(マウスキャプチャ+追従ゴースト)。
-- ドロップ位置の確定は `windows` struct でスクリーン座標からクラス名"CustToolbar"の
-- ウィンドウ(HWND)を特定する。

global ToolPalette_Form
global ToolPalette_Ghost
global ToolPalette_DragActive
global ToolPalette_DragDef
global ToolPalette_DragStartPt
global ToolPalette_LastGhostSize -- デバッグ用: #(ghostW, ghostH, sourceBtnW, sourceBtnH)
global ToolPalette_LastDrop -- デバッグ用: #(dropX, dropY, foundHwnd, cmdId, addOk)

ToolPalette_DragActive = false
ToolPalette_DragDef = undefined

-- dotNetのHashtableはMAXScript struct値をItem[]経由でうまく格納できないため、
-- ボタン<->定義の対応は各ボタンのTagプロパティにToolPalette_Config内のインデックス(文字列)を
-- 持たせる方式にする。

try ( dotNet.loadAssembly "Autodesk.Max" ) catch ()

fn ToolPalette_Log msg =
(
	format "[ToolPalette] %\n" msg
)

fn ToolPalette_GI = (dotNetClass "Autodesk.Max.GlobalInterface").Instance

-- .NETの独立したフローティングFormはMaxのメインウィンドウとは無関係なため、
-- 放置するとMax本体を閉じてもウィンドウが残り、プロセスが終了できなくなることがある。
-- Win32のGWL_HWNDPARENT(-8)でMaxメインウィンドウを「オーナー」に設定しておくと、
-- メインウィンドウが破棄される時にOS側で自動的に一緒に閉じられるようになる。
fn ToolPalette_SetOwnerToMax formObj =
(
	try
	(
		local mainHwnd = windows.getMAXHWND()
		windows.setWindowLong formObj.Handle -8 mainHwnd
	)
	catch ()
)

------------------------------------------------------------------------
-- Win32 ウィンドウ探索
------------------------------------------------------------------------

-- windows.getChildrenHWND の1件の戻り値要素は #(hwnd, parent, owner, class, caption, flag, root1, root2)
fn ToolPalette_ParseChildEntry entry =
(
	local hwnd = undefined
	local cls = ""
	local cap = ""
	try
	(
		if classOf entry == Array and entry.count >= 5 then
		(
			hwnd = entry[1]
			cls = entry[4] as string
			cap = entry[5] as string
		)
		else if classOf entry == Array and entry.count >= 1 then
		(
			hwnd = entry[1]
		)
		else
		(
			hwnd = entry
		)
	)
	catch ()
	#(hwnd, cls, cap)
)

-- windows.getChildrenHWND は実機では対象hwnd配下を再帰的に(トップレベルの
-- 別ウィンドウとしてドッキングされたツールバーも含めて)返してくることを確認済み。
fn ToolPalette_CollectAll mainHwnd =
(
	local results = #()
	local raw = #()
	try ( raw = windows.getChildrenHWND mainHwnd ) catch ( raw = #() )
	for c in raw do
	(
		local parsed = ToolPalette_ParseChildEntry c
		if parsed[1] != undefined do append results parsed
	)
	results
)

fn ToolPalette_RectToArray r =
(
	local out = undefined
	try
	(
		if classOf r == Array and r.count >= 4 then
			out = #(r[1], r[2], r[3], r[4])
	)
	catch ()
	if out == undefined do
	(
		try ( out = #(r.left, r.top, r.right, r.bottom) ) catch ()
	)
	if out == undefined do
	(
		try ( out = #(r.x0, r.y0, r.x1, r.y1) ) catch ()
	)
	out
)

fn ToolPalette_PointInRect px py rectArr =
(
	rectArr != undefined and \
	px >= rectArr[1] and px <= rectArr[3] and \
	py >= rectArr[2] and py <= rectArr[4]
)

-- スクリーン座標 (px, py) 上にある "CustToolbar" ウィンドウのhwndを返す(複数重なる場合は面積最小=最も内側を優先)。
fn ToolPalette_FindToolbarHwndAtScreenPoint px py =
(
	local mainHwnd = 0
	try ( mainHwnd = windows.getMAXHWND() ) catch ( mainHwnd = 0 )
	local all = ToolPalette_CollectAll mainHwnd
	local best = undefined
	local bestArea = 1e12
	for entry in all do
	(
		local hwnd = entry[1]
		local cls = entry[2]
		if cls == "CustToolbar" then
		(
			local rectArr = undefined
			try ( rectArr = ToolPalette_RectToArray (windows.getWindowPos hwnd) ) catch ()
			if rectArr != undefined and (ToolPalette_PointInRect px py rectArr) then
			(
				local area = (rectArr[3]-rectArr[1]) * (rectArr[4]-rectArr[2])
				if area < bestArea then
				(
					bestArea = area
					best = hwnd
				)
			)
		)
	)
	best
)

------------------------------------------------------------------------
-- macroScript -> cmdId 検索(ActionManagerの "マクロ スクリプト" テーブル)
------------------------------------------------------------------------

global ToolPalette_MacroTableIndex = 98 -- ToolPalette_RunDiagnostics() で毎回自動検出し直すので通常は変更不要

fn ToolPalette_FindMacroTable =
(
	local gi = ToolPalette_GI()
	local am = gi.COREInterface17.ActionManager
	local n = am.NumActionTables
	local found = -1
	for i = 0 to n - 1 do
	(
		local tbl = am.GetTable i
		local nm = ""
		try ( nm = tbl.Name ) catch ()
		if nm == "マクロ スクリプト" or nm == "Macro Scripts" or (findString (toLower nm) "macro") != undefined then
			found = i
	)
	found
)

fn ToolPalette_FindMacroCmdId macroName category =
(
	local gi = ToolPalette_GI()
	local am = gi.COREInterface17.ActionManager
	local tbl = am.GetTable ToolPalette_MacroTableIndex
	local cnt = tbl.Count
	local found = -1
	for i = 0 to cnt - 1 do
	(
		local item = undefined
		try ( item = tbl.GetActionByIndex i ) catch ()
		if item != undefined then
		(
			local me = undefined
			try ( me = item.MacroScript ) catch ()
			if me != undefined then
			(
				local nm = ""
				local cat = ""
				try ( nm = me.Name ) catch ()
				try ( cat = me.Category ) catch ()
				-- item.Id_ が本来の安定したコマンドID。ループのインデックス(i)は
				-- 単なる配列位置であり、MacroButtonData.Createにはこちらではなく
				-- item.Id_ を渡す必要がある(実行やアイコン表示はたまたま動くが、
				-- 右クリックの「マクロスクリプトを編集」等はIDの不一致で失敗する)。
				if nm == macroName and cat == category do found = item.Id_
			)
		)
	)
	found
)

------------------------------------------------------------------------
-- ツールバーへの配置 & 永続化
------------------------------------------------------------------------

-- toolbarHwndの直接の子ウィンドウ(CustButton等)を左から順に見て、dropXがどの
-- 2つの既存ボタンの間に来るかを求め、その間に挿入するための位置(0-based)を返す。
-- 見つからない場合は末尾(numItems)を返す。
fn ToolPalette_ComputeInsertPos toolbarHwnd dropX =
(
	local gi = ToolPalette_GI()
	local tb = gi.GetICustToolbar toolbarHwnd
	local insertPos = tb.NumItems
	local raw = #()
	try ( raw = windows.getChildrenHWND toolbarHwnd ) catch ( raw = #() )
	-- pos(AddToolの挿入位置)はボタンだけでなくセパレータ/コンボボックスなど
	-- 全アイテム種別を通しての順序なので、コンボボックス内部のEditのような
	-- 入れ子の実装詳細クラスだけ除外して数える。
	local excludeClasses = #("Edit", "EDITDUMMY", "ComboLBox", "ScrollBar", "msctls_progress32", "Static", "SysListView32")
	local centers = #()
	for c in raw do
	(
		local parsed = ToolPalette_ParseChildEntry c
		if parsed[1] != undefined and (findItem excludeClasses parsed[2]) == 0 then
		(
			local r = undefined
			try ( r = windows.getWindowPos parsed[1] ) catch ()
			if r != undefined do append centers ((r.left + r.right) / 2.0)
		)
	)
	-- 列挙順が必ずしも左から右の視覚的順序と一致しないため、座標でソートしてから判定する
	sort centers
	for i = 1 to centers.count do
	(
		if dropX < centers[i] then
		(
			insertPos = i - 1
			exit
		)
	)
	insertPos
)

-- iconNameは登録済みQtリソースのエイリアス名(拡張子・スラッシュなし)。
-- MacroButtonDataの legacy な imageID/imageName ではなく、Qt時代の
-- IconName_ プロパティ(内部で MaxSDK::LoadMaxMultiResIcon を使う)に
-- ":/<iconName>" 形式で渡すことで、動的追加したボタンでも確実に表示される。
--
-- 2026-07-31 判明: 以前使っていた gi.ToolButtonItem.Create は致命的に誤り。
-- C++ SDK(custcont.h)上、ToolButtonItem は単なる汎用プッシュ/チェックボタンで、
-- マクロ実行の仕組み(cmdID/tblID)を一切持たない。しかも非公開コンストラクタが
-- `type == CTB_PUSHBUTTON ? CTB_PUSHBUTTON : CTB_CHECKBUTTON` という判定をしており、
-- ToolItemType.Macrobutton を渡しても黙って CTB_CHECKBUTTON に矯正される。
-- そのため「クリックすると押下ハイライトが切り替わるだけでマクロが実行されない」
-- という不具合が起きていた(cmdIdは実際にはhID=ヘルプID引数に渡っていただけで、
-- どこにもマクロとの結び付きが無かった)。
-- 正しくは MacroButtonData(tblID, cmdID, ...) + ToolMacroItem を使う(ファイル冒頭の
-- 初期実装コメント参照)。これは実機のUIが生成するボタンと同じ macroType=MB_TYPE_ACTION(3)
-- になり、かつ IconName_ でアイコンも指定できる。なお tblID は action table の
-- ループインデックスではなく tbl.Id_ (本来の ActionTableId) を渡す必要がある。
-- 実機確認: macroType=3, 再起動後もアイコン表示(NOTIFY_TOOLBARS_PRE_LOADの早期
-- Qtリソース登録と併用)、クリックでマクロが実際に実行されることを確認済み。
--
-- 注意: ToolMacroItem の C++ 実装は id を常に 0 に固定する
-- (ToolItem(CTB_MACROBUTTON, 0, 0, wd, ht, ori))。そのため fixedId 引数は
-- もはや tb.FindItem/tb.DeleteItemByID による一意識別には使えない
-- (ToolButtonItem時代の名残として引数だけ残してあるが未使用)。
--
-- 2026-07-31 追記: ToolMacroItem.Create の wd/ht にハードコードしていた 24,24 は誤り。
-- 実機で純正ボタン(CustButton)のウィンドウサイズを windows.getWindowPos で実測したところ
-- 31x30 pxであり、本ツールのボタンだけ純正より一回り小さく表示される原因になっていた
-- (ユーザー指摘: 「他の純正アイコンより明らかに1mmくらい縦横小さい」)。DPI/ズーム設定に
-- よってこの値が変わりうるため、ハードコードせず配置先ツールバー上の既存の純正ボタンを
-- 実測してそのサイズに合わせる。
fn ToolPalette_GetNativeButtonSize toolbarHwnd =
(
	local result = #(31, 30) -- 実機のCustButton実測値をフォールバックにする
	try
	(
		local children = windows.getChildrenHWND toolbarHwnd
		for c in children do
		(
			local parsed = ToolPalette_ParseChildEntry c
			if parsed[2] == "CustButton" then
			(
				local r = undefined
				try ( r = windows.getWindowPos parsed[1] ) catch ()
				if r != undefined then
				(
					local w = r.right - r.left
					local h = r.bottom - r.top
					if w > 0 and h > 0 then
					(
						result = #(w, h)
						exit
					)
				)
			)
		)
	)
	catch ()
	result
)

fn ToolPalette_PlaceMacroOnToolbarHwnd hwnd cmdId label tooltip pos iconName fixedId =
(
	local success = false
	try
	(
		local gi = ToolPalette_GI()
		local tb = gi.GetICustToolbar hwnd
		local mIdx = ToolPalette_FindMacroTable()
		ToolPalette_MacroTableIndex = mIdx
		local tbl = gi.COREInterface17.ActionManager.GetTable mIdx
		local tblId = tbl.Id_
		local iconRes = if iconName != undefined and iconName != "" then (":" + iconName) else ""
		local mbd = gi.MacroButtonData.Create tblId cmdId label tooltip -1 ""
		if iconRes != "" do mbd.IconName_ = iconRes
		local ori = 3 + 12 + 16 -- CTB_HORIZ|CTB_VERT|CTB_FLOAT (custcont.h)
		local btnSize = ToolPalette_GetNativeButtonSize hwnd
		local tmi = gi.ToolMacroItem.Create btnSize[1] btnSize[2] mbd ori
		tb.AddTool tmi pos
		success = true
	)
	catch
	(
		ToolPalette_Log ("配置中に例外: " + (getCurrentException()))
	)
	success
)

fn ToolPalette_PersistCUI =
(
	local success = false
	try
	(
		cui.SaveConfig()
		success = true
		ToolPalette_Log ("ワークスペースを保存しました: " + (cui.getConfigFile() as string))
	)
	catch
	(
		ToolPalette_Log ("保存中に例外: " + (getCurrentException()))
	)
	success
)

------------------------------------------------------------------------
-- ツールバーの安定識別子(objectName)
------------------------------------------------------------------------
-- CustToolbarのhwndはセッションをまたいで変わるが、それをホストするQt
-- ウィジェット(QmaxToolBar)のobjectName(例:"Main Toolbar")は.cuixにも
-- 保存される安定した名前であり、セッションをまたいでツールバーを再特定
-- するのに使える。実機確認: CustToolbarのhwnd -> windows.getParentHWND
-- (ドッキングホスト) -> QWidget.find(parentHwnd) -> .parent() を数階層
-- さかのぼると空でないobjectNameに到達する。

fn ToolPalette_GetToolbarObjectName hwnd =
(
	local result = ""
	try
	(
		local parentHwnd = windows.getParentHWND hwnd
		local qtw = python.import "PySide6.QtWidgets"
		local w = qtw.QWidget.find parentHwnd
		local depth = 0
		while w != undefined and depth < 8 and result == "" do
		(
			local nm = ""
			try ( nm = w.objectName() as string ) catch ()
			if nm != "" do result = nm
			w = w.parent()
			depth += 1
		)
	)
	catch ()
	result
)

fn ToolPalette_FindToolbarHwndByObjectName targetName =
(
	local found = undefined
	try
	(
		local mainHwnd = windows.getMAXHWND()
		local all = ToolPalette_CollectAll mainHwnd
		for entry in all do
		(
			if found == undefined and entry[2] == "CustToolbar" do
			(
				local nm = ToolPalette_GetToolbarObjectName entry[1]
				if nm == targetName do found = entry[1]
			)
		)
	)
	catch ()
	found
)

------------------------------------------------------------------------
-- 配置場所の永続化(ToolPalette_Placements.txt)
------------------------------------------------------------------------
-- .cuixへの保存だけでは、MB_TYPE_ACTION_CUSTOM種別のボタンが再起動後に
-- 正しく再描画されない(既知の制約、上のToolPalette_PlaceMacroOnToolbarHwnd
-- のコメント参照)。そのため「どのボタン(fixedId)をどのツールバー
-- (objectName)に置いたか」を自前のテキストファイルに記録しておき、
-- 起動時に毎回それを読んで作り直す(ToolPalette_ReconcileOnStartup)。
-- 1行1件、タブ区切りで "fixedId<TAB>objectName" の形式。

-- このファイル(ToolPalette.ms)自身の設置場所を基準にした相対パス。配布先の
-- ユーザーがどこにフォルダを置いても動くよう、このマシン固有の絶対パスは使わない。
global ToolPalette_PlacementsFile = (getFilenamePath (getSourceFileName())) + "ToolPalette_Placements.txt"

fn ToolPalette_LoadPlacements =
(
	local result = #()
	try
	(
		if (getFiles ToolPalette_PlacementsFile).count > 0 then
		(
			local f = openFile ToolPalette_PlacementsFile mode:"r"
			while not eof f do
			(
				local line = readLine f
				local parts = filterString line "\t"
				if parts.count >= 2 do append result #(parts[1] as integer, parts[2])
			)
			close f
		)
	)
	catch ()
	result
)

fn ToolPalette_SavePlacementsRaw arr =
(
	local success = false
	try
	(
		local f = createFile ToolPalette_PlacementsFile
		for rec in arr do format "%\t%\n" rec[1] rec[2] to:f
		close f
		success = true
	)
	catch ()
	success
)

-- fixedIdに対応するレコードをobjectNameで追加/上書きする。
fn ToolPalette_RecordPlacement fixedId objectName =
(
	local list = ToolPalette_LoadPlacements()
	local updated = false
	for rec in list do
	(
		if rec[1] == fixedId do ( rec[2] = objectName; updated = true )
	)
	if not updated do append list #(fixedId, objectName)
	ToolPalette_SavePlacementsRaw list
)

-- fixedIdからToolPalette_Config内の該当定義を探す。
fn ToolPalette_FindConfigById fixedId =
(
	local found = undefined
	for def in ToolPalette_Config do
	(
		if found == undefined and def.id == fixedId do found = def
	)
	found
)

-- 3ds Max起動時に呼ぶ。Placementsファイルに記録された各ボタンについて、
-- 対応するツールバーを名前で再特定し、既存の同一IDアイテムを削除してから
-- 新しいiconNameで作り直す(位置は末尾固定。厳密な元位置の復元はしない)。
fn ToolPalette_ReconcileOnStartup =
(
	local mIdx = ToolPalette_FindMacroTable()
	ToolPalette_MacroTableIndex = mIdx
	local list = ToolPalette_LoadPlacements()
	local changed = false
	for rec in list do
	(
		local fixedId = rec[1]
		local objectName = rec[2]
		local def = ToolPalette_FindConfigById fixedId
		if def != undefined then
		(
			local hwnd = ToolPalette_FindToolbarHwndByObjectName objectName
			if hwnd == undefined then
			(
				ToolPalette_Log ("再配置スキップ(ツールバーが見つかりません): " + objectName)
			)
			else
			(
				local cmdId = ToolPalette_FindMacroCmdId def.macroName def.category
				if cmdId < 0 then
				(
					ToolPalette_Log ("再配置スキップ(macroScriptが見つかりません): " + def.macroName)
				)
				else
				(
					local placed = ToolPalette_PlaceMacroOnToolbarHwnd hwnd cmdId def.label def.tooltip -1 def.iconName fixedId
					if placed do changed = true
					ToolPalette_Log (def.label + " を再配置しました (" + objectName + ")")
				)
			)
		)
	)
	if changed do ToolPalette_PersistCUI()
)

------------------------------------------------------------------------
-- 診断用ユーティリティ
------------------------------------------------------------------------

fn ToolPalette_RunDiagnostics =
(
	ToolPalette_Log "=== ToolPalette Diagnostics start ==="
	local mainHwnd = 0
	try ( mainHwnd = windows.getMAXHWND() ) catch ( mainHwnd = 0 )
	ToolPalette_Log ("Main HWND: " + (mainHwnd as string))

	local all = ToolPalette_CollectAll mainHwnd
	local toolbars = for e in all where e[2] == "CustToolbar" collect e
	ToolPalette_Log ("CustToolbar 数: " + (toolbars.count as string))
	for entry in toolbars do
	(
		local rectArr = undefined
		try ( rectArr = ToolPalette_RectToArray (windows.getWindowPos entry[1]) ) catch ()
		format "hwnd:% caption:% rect:%\n" entry[1] entry[3] rectArr
	)

	local mIdx = ToolPalette_FindMacroTable()
	ToolPalette_MacroTableIndex = mIdx
	ToolPalette_Log ("マクロテーブル index: " + (mIdx as string))

	for def in ToolPalette_Config do
	(
		local cmdId = ToolPalette_FindMacroCmdId def.macroName def.category
		format "macro:% category:% -> cmdId:%\n" def.macroName def.category cmdId
	)

	ToolPalette_Log ("現在のワークスペースファイル: " + (cui.getConfigFile() as string))
	ToolPalette_Log "=== ToolPalette Diagnostics end ==="
)

------------------------------------------------------------------------
-- パレットUI(.NET)
------------------------------------------------------------------------

fn ToolPalette_HideGhost =
(
	if ToolPalette_Ghost != undefined then
	(
		try ( ToolPalette_Ghost.Close() ) catch ()
		ToolPalette_Ghost = undefined
	)
)

fn ToolPalette_ShowGhost def sourceBtn =
(
	ToolPalette_HideGhost()
	local g = dotNetObject "System.Windows.Forms.Form"
	g.FormBorderStyle = (dotNetClass "System.Windows.Forms.FormBorderStyle").None
	g.TopMost = true
	g.ShowInTaskbar = false
	g.StartPosition = (dotNetClass "System.Windows.Forms.FormStartPosition").Manual
	g.AutoSize = false
	local smallerSide = if sourceBtn.Width < sourceBtn.Height then sourceBtn.Width else sourceBtn.Height
	local ghostSide = smallerSide / 2
	local sz = dotNetObject "System.Drawing.Size" ghostSide ghostSide
	-- MinimumSize/MaximumSizeも固定し、内部コントロールによる自動リサイズを防ぐ
	g.MinimumSize = sz
	g.MaximumSize = sz
	g.Size = sz
	g.Opacity = 0.8
	g.BackColor = (dotNetClass "System.Drawing.Color").LightYellow

	local pic = dotNetObject "System.Windows.Forms.PictureBox"
	pic.Dock = (dotNetClass "System.Windows.Forms.DockStyle").Fill
	pic.SizeMode = (dotNetClass "System.Windows.Forms.PictureBoxSizeMode").Zoom
	if def.iconPath != undefined then
	(
		try ( pic.Image = dotNetObject "System.Drawing.Bitmap" def.iconPath ) catch ()
	)
	if pic.Image == undefined then
	(
		local lbl = dotNetObject "System.Windows.Forms.Label"
		lbl.Text = def.label
		lbl.Dock = (dotNetClass "System.Windows.Forms.DockStyle").Fill
		lbl.TextAlign = (dotNetClass "System.Drawing.ContentAlignment").MiddleCenter
		g.Controls.Add lbl
	)
	else
	(
		g.Controls.Add pic
	)

	g.Show()
	ToolPalette_SetOwnerToMax g
	ToolPalette_Ghost = g
	ToolPalette_LastGhostSize = #(g.Width, g.Height, sourceBtn.Width, sourceBtn.Height)
)

fn ToolPalette_MoveGhostToCursor =
(
	if ToolPalette_Ghost != undefined then
	(
		local p = (dotNetClass "System.Windows.Forms.Cursor").Position
		local pt = dotNetObject "System.Drawing.Point" (p.X - (ToolPalette_Ghost.Width / 2)) (p.Y - (ToolPalette_Ghost.Height / 2))
		ToolPalette_Ghost.Location = pt
	)
)

fn ToolPalette_DefFromSender sender =
(
	local def = undefined
	try
	(
		local idx = (sender.Tag as string) as integer
		if idx != undefined and idx >= 1 and idx <= ToolPalette_Config.count do
			def = ToolPalette_Config[idx]
	)
	catch ()
	def
)

fn ToolPalette_OnBtnMouseDown sender args =
(
	ToolPalette_DragActive = false
	ToolPalette_DragDef = ToolPalette_DefFromSender sender
	local p = (dotNetClass "System.Windows.Forms.Cursor").Position
	ToolPalette_DragStartPt = #(p.X, p.Y)
	sender.Capture = true
)

fn ToolPalette_OnBtnMouseMove sender args =
(
	if ToolPalette_DragDef != undefined and sender.Capture then
	(
		local p = (dotNetClass "System.Windows.Forms.Cursor").Position
		if not ToolPalette_DragActive then
		(
			local dx = p.X - ToolPalette_DragStartPt[1]
			local dy = p.Y - ToolPalette_DragStartPt[2]
			if (abs dx) > 6 or (abs dy) > 6 then
			(
				ToolPalette_DragActive = true
				ToolPalette_ShowGhost ToolPalette_DragDef sender
				sender.Capture = true
			)
		)
		if ToolPalette_DragActive do ToolPalette_MoveGhostToCursor()
	)
)

fn ToolPalette_OnBtnMouseUp sender args =
(
	sender.Capture = false
	local wasDragging = ToolPalette_DragActive
	local def = ToolPalette_DragDef
	ToolPalette_HideGhost()
	ToolPalette_DragActive = false
	ToolPalette_DragDef = undefined

	if def == undefined then return OK

	if not wasDragging then
	(
		-- ドラッグ量が閾値以下: 通常クリックとしてそのままマクロを実行する
		try ( macros.run def.category def.macroName ) catch ( ToolPalette_Log ("実行失敗: " + def.macroName) )
	)
	else
	(
		local p = (dotNetClass "System.Windows.Forms.Cursor").Position
		local hwnd = ToolPalette_FindToolbarHwndAtScreenPoint p.X p.Y
		ToolPalette_LastDrop = #(p.X, p.Y, hwnd, undefined, undefined)
		if hwnd == undefined then
		(
			ToolPalette_Log "ツールバー上でドロップされませんでした(何もしません)"
		)
		else
		(
			local cmdId = ToolPalette_FindMacroCmdId def.macroName def.category
			ToolPalette_LastDrop[4] = cmdId
			if cmdId < 0 then
			(
				ToolPalette_Log ("macroScriptが見つかりません: " + def.macroName + " / " + def.category)
			)
			else
			(
				local insertPos = ToolPalette_ComputeInsertPos hwnd p.X
				local placed = ToolPalette_PlaceMacroOnToolbarHwnd hwnd cmdId def.label def.tooltip insertPos def.iconName def.id
				ToolPalette_LastDrop[5] = placed
				if placed then
				(
					if def.id != undefined do
					(
						local objName = ToolPalette_GetToolbarObjectName hwnd
						if objName != "" do ToolPalette_RecordPlacement def.id objName
					)
					ToolPalette_PersistCUI()
					ToolPalette_Log (def.label + " をツールバー(hwnd:" + (hwnd as string) + ")に配置しました")
				)
			)
		)
	)
)

fn ToolPalette_BuildUI =
(
	local form = dotNetObject "System.Windows.Forms.Form"
	form.Text = "Tool Palette"
	form.StartPosition = (dotNetClass "System.Windows.Forms.FormStartPosition").CenterScreen
	form.TopMost = true
	form.Width = 200
	form.Height = 160
	form.FormBorderStyle = (dotNetClass "System.Windows.Forms.FormBorderStyle").SizableToolWindow

	local flow = dotNetObject "System.Windows.Forms.FlowLayoutPanel"
	flow.Dock = (dotNetClass "System.Windows.Forms.DockStyle").Fill
	flow.FlowDirection = (dotNetClass "System.Windows.Forms.FlowDirection").LeftToRight
	flow.WrapContents = true
	flow.AutoScroll = true
	form.Controls.Add flow

	for i = 1 to ToolPalette_Config.count do
	(
		local def = ToolPalette_Config[i]
		local btn = dotNetObject "System.Windows.Forms.Button"
		btn.Width = 56
		btn.Height = 56
		btn.Margin = dotNetObject "System.Windows.Forms.Padding" 4 4 4 4
		btn.Tag = i as string
		btn.TextImageRelation = (dotNetClass "System.Windows.Forms.TextImageRelation").ImageAboveText
		btn.ImageAlign = (dotNetClass "System.Drawing.ContentAlignment").MiddleCenter
		btn.TextAlign = (dotNetClass "System.Drawing.ContentAlignment").BottomCenter
		btn.Font = dotNetObject "System.Drawing.Font" "Segoe UI" 7.0

		if def.iconPath != undefined then
		(
			try
			(
				local rawImg = dotNetObject "System.Drawing.Bitmap" def.iconPath
				local resized = dotNetObject "System.Drawing.Bitmap" rawImg 28 28
				btn.Image = resized
			)
			catch ()
		)
		btn.Text = def.label

		local tip = dotNetObject "System.Windows.Forms.ToolTip"
		tip.SetToolTip btn def.tooltip

		dotNet.addEventHandler btn "MouseDown" ToolPalette_OnBtnMouseDown
		dotNet.addEventHandler btn "MouseMove" ToolPalette_OnBtnMouseMove
		dotNet.addEventHandler btn "MouseUp" ToolPalette_OnBtnMouseUp

		flow.Controls.Add btn
	)

	form
)

fn ToolPalette_ShowWindow =
(
	if ToolPalette_Form == undefined or (try (ToolPalette_Form.IsDisposed) catch (true)) then
		ToolPalette_Form = ToolPalette_BuildUI()
	ToolPalette_Form.Show()
	ToolPalette_SetOwnerToMax ToolPalette_Form
	ToolPalette_Form.BringToFront()
)

------------------------------------------------------------------------
-- 起動用 macroScript
------------------------------------------------------------------------

macroScript ToolPalette_Open
	category:"ToolPalette"
	buttonText:"Tool Palette"
	toolTip:"Open Tool Palette (drag buttons onto a toolbar to install them)"
(
	on execute do ToolPalette_ShowWindow()
)

macroScript ToolPalette_Diagnostics
	category:"ToolPalette"
	buttonText:"Tool Palette Diagnostics"
	toolTip:"ツールバー検出/ActionManager挙動を診断してリスナーに出力する"
(
	on execute do ToolPalette_RunDiagnostics()
)

ToolPalette_Log "ロード完了。ToolPalette_ShowWindow() でパレットを開けます(または ToolPalette カテゴリの Tool Palette マクロ)。"
