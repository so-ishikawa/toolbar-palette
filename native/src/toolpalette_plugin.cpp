// ToolPalette.gup — スタンドアロンの3ds Maxプラグイン(v2: .NET不使用、FPStaticInterfaceでpymxsに公開)。
//
// 設計方針(2026-07-31大改修):
//   - ツールバー/アクションテーブル操作は .NET(Autodesk.Max アセンブリ)を一切経由せず、
//     3ds Max SDKのネイティブC++クラス(ICustToolbar・IActionManager・ActionItem・MacroEntry・
//     MacroButtonData・ToolMacroItem・CUIFrameMgr)を直接呼ぶ。
//   - これらの機能を FPStaticInterface として公開し、Python側からは
//     `pymxs.runtime.ToolPalette.placeButton(...)` のように、MAXScriptファイルを一切介さず
//     直接呼び出せるようにする(3ds Max公式サンプル gup\pluginmanager と同じ設計パターン)。
//   - 起動時のフック(Qtアイコン早期登録・NOTIFY_SYSTEM_STARTUP)はC++側に残す(タイミングが
//     シビアで、MAXScript/Pythonエンジンの初期化を待てないため)。この処理から
//     `python.executeFile` を1行呼ぶことだけがMAXScriptとの唯一の接点。
//   - パレットUI・ドラッグ検出・設定データはすべてPython(PySide6)側に移動。

#include <max.h>
#include <gup.h>
#include <notify.h>
#include <custcont.h>
#include <actiontable.h>
#include <imacroscript.h>
#include <ifnpub.h>
#include <plugapi.h>
#include <maxscript/maxscript.h>
#include <maxscript/foundation/strings.h>
#include <CoreFunctions.h>
#include <string>
#include <vector>
#include <algorithm>
#include <climits>
#if MAX_SDK_VERSION >= 2027
#include <QtCore/QResource>
#endif

#define TOOLPALETTE_CLASS_ID Class_ID(0x54504c54, 0x504c5445)
#define TOOLPALETTE_FN_INTERFACE Interface_ID(0x67a1f3d2, 0x1e5c4a91)

HINSTANCE hInstance = nullptr;

// ── パス解決: 自分自身(このDLL)の設置ディレクトリを基準にする ──────
static std::wstring GetPluginDirectory() {
    wchar_t path[MAX_PATH] = {0};
    GetModuleFileNameW(hInstance, path, MAX_PATH);
    std::wstring p(path);
    size_t pos = p.find_last_of(L"\\/");
    return (pos == std::wstring::npos) ? L"." : p.substr(0, pos);
}

static void RunMAXScriptSimple(const std::wstring& script) {
    FPValue fpv;
    try {
        ExecuteMAXScriptScript(script.c_str(), MAXScript::ScriptSource::NonEmbedded, FALSE, &fpv, TRUE);
    } catch (...) {
    }
}

// ── Qtアイコンリソースの登録 ─────────────────────────────────────
static void RegisterToolPaletteQtResource() {
    std::wstring rccPath = GetPluginDirectory() + L"\\qtres\\toolpalette.rcc";
#if MAX_SDK_VERSION >= 2027
    QResource::registerResource(QString::fromStdWString(rccPath));
#else
    std::wstring script =
        L"try ( local qtcore = python.import \"PySide6.QtCore\"; qtcore.QResource.registerResource @\"" +
        rccPath + L"\" ) catch ()";
    RunMAXScriptSimple(script);
#endif
}

static void OnToolbarsPreLoad(void*, NotifyInfo*) { RegisterToolPaletteQtResource(); }
static void OnCuiMenusPreLoad(void*, NotifyInfo*) { RegisterToolPaletteQtResource(); }

// ── 起動完了後: Pythonブートストラップの起動 + アイコン再読込 ──────
static BOOL CALLBACK ResetToolbarIconsEnumProc(HWND hwnd, LPARAM) {
    TCHAR className[64] = {0};
    if (GetClassName(hwnd, className, _countof(className)) > 0 &&
        _tcscmp(className, _T("CustToolbar")) == 0) {
        ICustToolbar* tb = GetICustToolbar(hwnd);
        if (tb) {
            tb->ResetIconImages();
            ReleaseICustToolbar(tb);
        }
    }
    return TRUE;
}

static void RefreshAllToolbarIcons() {
    Interface* ip = GetCOREInterface();
    if (!ip) return;
    HWND mainHwnd = ip->GetMAXHWnd();
    if (!mainHwnd) return;
    EnumChildWindows(mainHwnd, ResetToolbarIconsEnumProc, 0);
}

// scripts\startup が機能しない環境があるため、標準の自動ロード機構には頼らず、
// ここでPythonブートストラップスクリプトを直接実行する。これがMAXScriptとの唯一の接点。
static void LaunchPythonBootstrap() {
    std::wstring dir = GetPluginDirectory();
    std::wstring pyPath = dir + L"\\python\\toolpalette_bootstrap.py";
    std::wstring script =
        L"try ( python.executeFile @\"" + pyPath + L"\" ) "
        L"catch ( format \"ToolPalette: bootstrap failed: %\\n\" (getCurrentException()) )";
    RunMAXScriptSimple(script);
}

static void OnSystemStartupDone(void*, NotifyInfo*) {
    UnRegisterNotification(OnSystemStartupDone, nullptr, NOTIFY_SYSTEM_STARTUP);
    LaunchPythonBootstrap();
    RefreshAllToolbarIcons();
}

static void RegisterToolPaletteHooks() {
    RegisterNotification(OnToolbarsPreLoad, nullptr, NOTIFY_TOOLBARS_PRE_LOAD);
    RegisterNotification(OnCuiMenusPreLoad, nullptr, NOTIFY_CUI_MENUS_PRE_LOAD);
    RegisterNotification(OnSystemStartupDone, nullptr, NOTIFY_SYSTEM_STARTUP);
#if MAX_SDK_VERSION >= 2027
    RegisterToolPaletteQtResource();
#endif
}

// ── Win32列挙ヘルパー ────────────────────────────────────────────
static bool IsExcludedChildClass(const TCHAR* cls) {
    static const TCHAR* kExclude[] = {
        _T("Edit"), _T("EDITDUMMY"), _T("ComboLBox"), _T("ScrollBar"),
        _T("msctls_progress32"), _T("Static"), _T("SysListView32")
    };
    for (auto* ex : kExclude) if (_tcscmp(cls, ex) == 0) return true;
    return false;
}

struct ButtonSizeCtx { bool found; int w; int h; };

static BOOL CALLBACK FindButtonSizeProc(HWND hwnd, LPARAM lparam) {
    ButtonSizeCtx* ctx = reinterpret_cast<ButtonSizeCtx*>(lparam);
    TCHAR cls[64] = {0};
    if (GetClassName(hwnd, cls, _countof(cls)) > 0 && _tcscmp(cls, _T("CustButton")) == 0) {
        RECT r;
        if (GetWindowRect(hwnd, &r)) {
            ctx->w = r.right - r.left;
            ctx->h = r.bottom - r.top;
            ctx->found = true;
            return FALSE;
        }
    }
    return TRUE;
}

struct PointCtx { int x; int y; HWND best; long bestArea; };

static BOOL CALLBACK FindAtPointProc(HWND hwnd, LPARAM lparam) {
    PointCtx* ctx = reinterpret_cast<PointCtx*>(lparam);
    TCHAR cls[64] = {0};
    if (GetClassName(hwnd, cls, _countof(cls)) > 0 && _tcscmp(cls, _T("CustToolbar")) == 0) {
        RECT r;
        if (GetWindowRect(hwnd, &r)) {
            if (ctx->x >= r.left && ctx->x <= r.right && ctx->y >= r.top && ctx->y <= r.bottom) {
                long area = static_cast<long>(r.right - r.left) * (r.bottom - r.top);
                if (area < ctx->bestArea) {
                    ctx->bestArea = area;
                    ctx->best = hwnd;
                }
            }
        }
    }
    return TRUE;
}

static BOOL CALLBACK ComputePosProc(HWND hwnd, LPARAM lparam) {
    std::vector<int>* centers = reinterpret_cast<std::vector<int>*>(lparam);
    TCHAR cls[64] = {0};
    GetClassName(hwnd, cls, _countof(cls));
    if (!IsExcludedChildClass(cls)) {
        RECT r;
        if (GetWindowRect(hwnd, &r)) {
            centers->push_back((r.left + r.right) / 2);
        }
    }
    return TRUE;
}

// ── GUP + FPStaticInterface: pymxs.runtime.ToolPalette.* として公開 ─────
class ToolPaletteGUP : public GUP, public FPStaticInterface {
public:
    // GUP
    DWORD Start() override { return GUPRESULT_KEEP; }
    void Stop() override {}
    void DeleteThis() override {} // staticシングルトンなのでdeleteしない
    DWORD_PTR Control(DWORD) override { return 0; }

    static ToolPaletteGUP& GetInstance() { return mInstance; }

    // ── 公開関数の実装 ──────────────────────────────────────────
    INT_PTR FpGetMaxHwnd() {
        Interface* ip = GetCOREInterface();
        return ip ? reinterpret_cast<INT_PTR>(ip->GetMAXHWnd()) : 0;
    }

    BOOL FpFindMacro(const MCHAR* macroName, const MCHAR* category) {
        mLastTblId = -1;
        mLastCmdId = -1;
        Interface* ip = GetCOREInterface();
        if (!ip || !macroName || !category) return FALSE;
        IActionManager* am = ip->GetActionManager();
        if (!am) return FALSE;
        int n = am->NumActionTables();
        for (int i = 0; i < n; i++) {
            ActionTable* tbl = am->GetTable(i);
            if (!tbl) continue;
            int cnt = tbl->Count();
            for (int j = 0; j < cnt; j++) {
                ActionItem* item = tbl->GetActionByIndex(j);
                if (!item) continue;
                MacroEntry* me = item->GetMacroScript();
                if (!me) continue;
                if (_wcsicmp(me->GetName().data(), macroName) == 0 &&
                    _wcsicmp(me->GetCategory().data(), category) == 0) {
                    mLastTblId = static_cast<int>(tbl->GetId());
                    mLastCmdId = item->GetId();
                    return TRUE;
                }
            }
        }
        return FALSE;
    }

    int FpGetLastTblId() { return mLastTblId; }
    int FpGetLastCmdId() { return mLastCmdId; }

    int FpGetNativeButtonWidth(INT_PTR toolbarHwnd) {
        ButtonSizeCtx ctx{false, 0, 0};
        EnumChildWindows(reinterpret_cast<HWND>(toolbarHwnd), FindButtonSizeProc, reinterpret_cast<LPARAM>(&ctx));
        return ctx.found ? ctx.w : 0;
    }

    int FpGetNativeButtonHeight(INT_PTR toolbarHwnd) {
        ButtonSizeCtx ctx{false, 0, 0};
        EnumChildWindows(reinterpret_cast<HWND>(toolbarHwnd), FindButtonSizeProc, reinterpret_cast<LPARAM>(&ctx));
        return ctx.found ? ctx.h : 0;
    }

    int FpComputeInsertPos(INT_PTR toolbarHwnd, int dropX) {
        std::vector<int> centers;
        EnumChildWindows(reinterpret_cast<HWND>(toolbarHwnd), ComputePosProc, reinterpret_cast<LPARAM>(&centers));
        std::sort(centers.begin(), centers.end());
        for (size_t i = 0; i < centers.size(); i++) {
            if (dropX < centers[i]) return static_cast<int>(i);
        }
        return static_cast<int>(centers.size());
    }

    BOOL FpPlaceButton(INT_PTR toolbarHwndRaw, int tblId, int cmdId, const MCHAR* label,
                       const MCHAR* tooltip, int pos, const MCHAR* iconName, int wd, int ht) {
        HWND hwnd = reinterpret_cast<HWND>(toolbarHwndRaw);
        ICustToolbar* tb = GetICustToolbar(hwnd);
        if (!tb) return FALSE;
        MacroButtonData mbd(static_cast<long>(tblId), cmdId, label, tooltip, -1, nullptr);
        if (iconName && iconName[0]) {
            std::wstring iconRes = std::wstring(L":") + iconName;
            mbd.SetIconName(iconRes.c_str());
        }
        int ori = 3 | 12 | 16; // CTB_HORIZ|CTB_VERT|CTB_FLOAT (custcont.h)
        ToolMacroItem tmi(wd, ht, &mbd, ori);
        tb->AddTool(tmi, pos);
        ReleaseICustToolbar(tb);
        return TRUE;
    }

    BOOL FpSaveConfig() {
        CUIFrameMgr* mgr = GetCUIFrameMgr();
        return (mgr && mgr->WriteConfig()) ? TRUE : FALSE;
    }

    INT_PTR FpFindToolbarAtPoint(int x, int y) {
        Interface* ip = GetCOREInterface();
        if (!ip) return 0;
        HWND mainHwnd = ip->GetMAXHWnd();
        PointCtx ctx{x, y, nullptr, LONG_MAX};
        EnumChildWindows(mainHwnd, FindAtPointProc, reinterpret_cast<LPARAM>(&ctx));
        return reinterpret_cast<INT_PTR>(ctx.best);
    }

    // ── Function Publishing ─────────────────────────────────────
    DECLARE_DESCRIPTOR(ToolPaletteGUP)
    enum {
        fn_getMaxHwnd, fn_findMacro, fn_getLastTblId, fn_getLastCmdId,
        fn_getNativeButtonWidth, fn_getNativeButtonHeight, fn_computeInsertPos,
        fn_placeButton, fn_saveConfig, fn_findToolbarAtPoint
    };
    BEGIN_FUNCTION_MAP
        FN_0(fn_getMaxHwnd, TYPE_INTPTR, FpGetMaxHwnd);
        FN_2(fn_findMacro, TYPE_BOOL, FpFindMacro, TYPE_STRING, TYPE_STRING);
        FN_0(fn_getLastTblId, TYPE_INT, FpGetLastTblId);
        FN_0(fn_getLastCmdId, TYPE_INT, FpGetLastCmdId);
        FN_1(fn_getNativeButtonWidth, TYPE_INT, FpGetNativeButtonWidth, TYPE_INTPTR);
        FN_1(fn_getNativeButtonHeight, TYPE_INT, FpGetNativeButtonHeight, TYPE_INTPTR);
        FN_2(fn_computeInsertPos, TYPE_INT, FpComputeInsertPos, TYPE_INTPTR, TYPE_INT);
        FN_9(fn_placeButton, TYPE_BOOL, FpPlaceButton, TYPE_INTPTR, TYPE_INT, TYPE_INT,
             TYPE_STRING, TYPE_STRING, TYPE_INT, TYPE_STRING, TYPE_INT, TYPE_INT);
        FN_0(fn_saveConfig, TYPE_BOOL, FpSaveConfig);
        FN_2(fn_findToolbarAtPoint, TYPE_INTPTR, FpFindToolbarAtPoint, TYPE_INT, TYPE_INT);
    END_FUNCTION_MAP

private:
    int mLastTblId = -1;
    int mLastCmdId = -1;
    static ToolPaletteGUP mInstance;
};

ToolPaletteGUP ToolPaletteGUP::mInstance(
    TOOLPALETTE_FN_INTERFACE, _T("ToolPaletteAPI"), 0, NULL, FP_CORE,
    fn_getMaxHwnd, _T("getMaxHwnd"), 0, TYPE_INTPTR, FP_NO_REDRAW, 0,
    fn_findMacro, _T("findMacro"), 0, TYPE_BOOL, FP_NO_REDRAW, 2,
        _T("macroName"), 0, TYPE_STRING,
        _T("category"), 0, TYPE_STRING,
    fn_getLastTblId, _T("getLastTblId"), 0, TYPE_INT, FP_NO_REDRAW, 0,
    fn_getLastCmdId, _T("getLastCmdId"), 0, TYPE_INT, FP_NO_REDRAW, 0,
    fn_getNativeButtonWidth, _T("getNativeButtonWidth"), 0, TYPE_INT, FP_NO_REDRAW, 1,
        _T("toolbarHwnd"), 0, TYPE_INTPTR,
    fn_getNativeButtonHeight, _T("getNativeButtonHeight"), 0, TYPE_INT, FP_NO_REDRAW, 1,
        _T("toolbarHwnd"), 0, TYPE_INTPTR,
    fn_computeInsertPos, _T("computeInsertPos"), 0, TYPE_INT, FP_NO_REDRAW, 2,
        _T("toolbarHwnd"), 0, TYPE_INTPTR,
        _T("dropX"), 0, TYPE_INT,
    fn_placeButton, _T("placeButton"), 0, TYPE_BOOL, FP_NO_REDRAW, 9,
        _T("toolbarHwnd"), 0, TYPE_INTPTR,
        _T("tblId"), 0, TYPE_INT,
        _T("cmdId"), 0, TYPE_INT,
        _T("label"), 0, TYPE_STRING,
        _T("tooltip"), 0, TYPE_STRING,
        _T("pos"), 0, TYPE_INT,
        _T("iconName"), 0, TYPE_STRING,
        _T("wd"), 0, TYPE_INT,
        _T("ht"), 0, TYPE_INT,
    fn_saveConfig, _T("saveConfig"), 0, TYPE_BOOL, FP_NO_REDRAW, 0,
    fn_findToolbarAtPoint, _T("findToolbarAtPoint"), 0, TYPE_INTPTR, FP_NO_REDRAW, 2,
        _T("x"), 0, TYPE_INT,
        _T("y"), 0, TYPE_INT,
    p_end
);

// ── ClassDesc ────────────────────────────────────────────────────
class ToolPaletteClassDesc : public ClassDesc2 {
public:
    int IsPublic() override { return TRUE; }
    void* Create(BOOL) override { return &ToolPaletteGUP::GetInstance(); }
    const TCHAR* ClassName() override { return _T("ToolPalette"); }
    const TCHAR* NonLocalizedClassName() override { return _T("ToolPalette"); }
    SClass_ID SuperClassID() override { return GUP_CLASS_ID; }
    Class_ID ClassID() override { return TOOLPALETTE_CLASS_ID; }
    const TCHAR* Category() override { return _T("ToolPalette"); }
    const TCHAR* InternalName() override { return _T("ToolPalette"); }
    HINSTANCE HInstance() override { return hInstance; }
};

static ToolPaletteClassDesc toolPaletteClassDesc;

// ── DLLエントリポイント ──────────────────────────────────────────
BOOL WINAPI DllMain(HINSTANCE hinstDLL, ULONG fdwReason, LPVOID) {
    if (fdwReason == DLL_PROCESS_ATTACH) {
        hInstance = hinstDLL;
        DisableThreadLibraryCalls(hinstDLL);
    }
    return TRUE;
}

__declspec(dllexport) const TCHAR* LibDescription() {
    return _T("ToolPalette - Drag & Drop Toolbar Placement");
}

__declspec(dllexport) int LibNumberClasses() {
    return 1;
}

__declspec(dllexport) ClassDesc* LibClassDesc(int i) {
    switch (i) {
        case 0: return &toolPaletteClassDesc;
        default: return nullptr;
    }
}

__declspec(dllexport) ULONG LibVersion() {
    return VERSION_3DSMAX;
}

__declspec(dllexport) int LibInitialize() {
    RegisterToolPaletteHooks();
    return TRUE;
}

__declspec(dllexport) int LibShutdown() {
    return TRUE;
}
