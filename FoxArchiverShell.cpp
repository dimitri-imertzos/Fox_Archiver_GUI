// FoxArchiverShell.cpp - Explorer context menu handler for FoxArchiver.
// Self-contained COM in-proc server. Build with static CRT (/MT) so Explorer
// has no runtime DLL/BPL dependency to fail on.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>      // IShellExtInit, IContextMenu3, CMINVOKECOMMANDINFO
#include <shellapi.h>    // HDROP, DragQueryFile, ShellExecuteEx
#include <shlwapi.h>
#include <strsafe.h>
#include <new>

#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "advapi32.lib")

// {96AF52A7-315D-450E-A439-5A4DC5316178}
static const CLSID CLSID_FoxArchiverCtxMenu =
    { 0x96AF52A7, 0x315D, 0x450E, {0xA4, 0x39, 0x5A, 0x4D, 0xC5, 0x31, 0x61, 0x78} };

static const wchar_t* kClsidString = L"{96AF52A7-315D-450E-A439-5A4DC5316178}";
static const wchar_t* kVerbName    = L"Fox_Archiver";
static const wchar_t* kProgId      = L"FoxArchiver.CtxMenu";
static const wchar_t* kFriendly    = L"fox_archiver Context Menu Handler";

static HINSTANCE g_hInst = nullptr;
static LONG      g_cRefDll = 0;

// Command offsets within our menu (relative to idCmdFirst)
enum {
    CMD_ADDTOARCHIVE = 0,
    CMD_ADDTONAMEDARC,
    CMD_ADDTONAMED7Z,
    CMD_ADDTONAMEDSTORE,     // store (no compression), via .arc + --md=store
    CMD_OPENARCHIVE,         // browse the archive in the viewer (no extract)
    CMD_DECOMPRESS_HERE,     // extract into the archive's own folder
    CMD_DECOMPRESS_TONAMED,  // extract into <archivefolder>\<basename>
    CMD_TEST_ARCHIVE,        // verify archive integrity (no extract)
    CMD_HASH_XXH32,          // hash the selection - XXH32
    CMD_HASH_XXH64,          // hash the selection - XXH64
    CMD_HASH_CRC32,          // hash the selection - CRC32
    CMD_HASH_CRC64,          // hash the selection - CRC64
    CMD_PARENT,              // the root "Fox_Archiver" item itself
    CMD_COUNT                // number of IDs we consume
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
static void GetModuleDir(wchar_t* out, size_t cch)
{
    GetModuleFileNameW(g_hInst, out, (DWORD)cch);
    wchar_t* slash = wcsrchr(out, L'\\');
    if (slash) *(slash + 1) = L'\0';
}

// Build a temp .lst file containing one selected path per line (UTF-8).
static bool WriteListFile(const wchar_t* const* files, UINT count, wchar_t* listPathOut, size_t cch)
{
    wchar_t tempDir[MAX_PATH];
    if (!GetTempPathW(MAX_PATH, tempDir)) return false;

    wchar_t name[MAX_PATH];
    GUID g; CoCreateGuid(&g);
    StringCchPrintfW(name, MAX_PATH,
        L"%sfox_archiver_%08X%04X%04X.lst", tempDir, g.Data1, g.Data2, g.Data3);

    HANDLE h = CreateFileW(name, GENERIC_WRITE, 0, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;

    // UTF-8 BOM
    const BYTE bom[3] = { 0xEF, 0xBB, 0xBF };
    DWORD wrote;
    WriteFile(h, bom, 3, &wrote, nullptr);

    for (UINT i = 0; i < count; ++i)
    {
        int need = WideCharToMultiByte(CP_UTF8, 0, files[i], -1, nullptr, 0, nullptr, nullptr);
        if (need > 1)
        {
            char* buf = new (std::nothrow) char[need + 2];
            if (buf)
            {
                WideCharToMultiByte(CP_UTF8, 0, files[i], -1, buf, need, nullptr, nullptr);
                // strip trailing null from the -1 conversion, add CRLF
                size_t len = strlen(buf);
                buf[len]   = '\r';
                buf[len+1] = '\n';
                WriteFile(h, buf, (DWORD)(len + 2), &wrote, nullptr);
                delete[] buf;
            }
        }
    }
    CloseHandle(h);
    StringCchCopyW(listPathOut, cch, name);
    return true;
}

// ---------------------------------------------------------------------------
// The shell extension object
// ---------------------------------------------------------------------------
class FoxCtxMenu : public IShellExtInit, public IContextMenu3
{
public:
    FoxCtxMenu() : m_cRef(1), m_files(nullptr), m_count(0)
    {
        InterlockedIncrement(&g_cRefDll);
    }
    ~FoxCtxMenu()
    {
        FreeFiles();
        InterlockedDecrement(&g_cRefDll);
    }

    // IUnknown
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv)
    {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (riid == IID_IUnknown || riid == IID_IShellExtInit)
            *ppv = static_cast<IShellExtInit*>(this);
        else if (riid == IID_IContextMenu || riid == IID_IContextMenu2 || riid == IID_IContextMenu3)
            *ppv = static_cast<IContextMenu3*>(this);
        else
            return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    IFACEMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&m_cRef); }
    IFACEMETHODIMP_(ULONG) Release()
    {
        ULONG c = InterlockedDecrement(&m_cRef);
        if (c == 0) delete this;
        return c;
    }

    // IShellExtInit
    IFACEMETHODIMP Initialize(PCIDLIST_ABSOLUTE, IDataObject* pdo, HKEY)
    {
        if (!pdo) return E_FAIL;
        FreeFiles();

        FORMATETC fe = { CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL };
        STGMEDIUM stg;
        if (FAILED(pdo->GetData(&fe, &stg))) return E_FAIL;

        HDROP hDrop = static_cast<HDROP>(GlobalLock(stg.hGlobal));
        if (!hDrop) { ReleaseStgMedium(&stg); return E_FAIL; }

        UINT n = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
        if (n > 0)
        {
            m_files = new (std::nothrow) wchar_t*[n];
            if (m_files)
            {
                m_count = 0;
                for (UINT i = 0; i < n; ++i)
                {
                    UINT len = DragQueryFileW(hDrop, i, nullptr, 0);
                    wchar_t* p = new (std::nothrow) wchar_t[len + 1];
                    if (p)
                    {
                        DragQueryFileW(hDrop, i, p, len + 1);
                        m_files[m_count++] = p;
                    }
                }
            }
        }
        GlobalUnlock(stg.hGlobal);
        ReleaseStgMedium(&stg);
        return (m_count > 0) ? S_OK : E_FAIL;
    }

    // IContextMenu
    IFACEMETHODIMP QueryContextMenu(HMENU hMenu, UINT indexMenu, UINT idCmdFirst,
                                    UINT idCmdLast, UINT uFlags)
    {
        if (uFlags & CMF_DEFAULTONLY)
            return MAKE_HRESULT(SEVERITY_SUCCESS, 0, 0);
        if (m_count == 0)
            return MAKE_HRESULT(SEVERITY_SUCCESS, 0, 0);

        wchar_t baseName[MAX_PATH];
        BuildBaseName(baseName, MAX_PATH);

        HMENU sub = CreatePopupMenu();
        wchar_t txt[MAX_PATH + 64];

        bool isArchive = SelectionIsArchive();

        if (isArchive)
        {
            // Archive actions: browse + extract + test, shown first for a single archive.
            AppendMenuW(sub, MF_STRING, idCmdFirst + CMD_OPENARCHIVE, L"Open archive");
            AppendMenuW(sub, MF_STRING, idCmdFirst + CMD_DECOMPRESS_HERE, L"Decompress here");
            StringCchPrintfW(txt, ARRAYSIZE(txt), L"Decompress to \"%s\\\"", baseName);
            AppendMenuW(sub, MF_STRING, idCmdFirst + CMD_DECOMPRESS_TONAMED, txt);
            AppendMenuW(sub, MF_STRING, idCmdFirst + CMD_TEST_ARCHIVE, L"Test archive");
            AppendMenuW(sub, MF_SEPARATOR, 0, nullptr);
        }

        // Compress actions (always available)
        AppendMenuW(sub, MF_STRING, idCmdFirst + CMD_ADDTOARCHIVE, L"Add to archive...");
        AppendMenuW(sub, MF_SEPARATOR, 0, nullptr);
        StringCchPrintfW(txt, ARRAYSIZE(txt), L"Add to \"%s.fxa\"", baseName);
        AppendMenuW(sub, MF_STRING, idCmdFirst + CMD_ADDTONAMEDARC, txt);
        StringCchPrintfW(txt, ARRAYSIZE(txt), L"Add to \"%s.7z\"", baseName);
        AppendMenuW(sub, MF_STRING, idCmdFirst + CMD_ADDTONAMED7Z, txt);
        StringCchPrintfW(txt, ARRAYSIZE(txt), L"Store to \"%s.fxa\"", baseName);
        AppendMenuW(sub, MF_STRING, idCmdFirst + CMD_ADDTONAMEDSTORE, txt);

        // Hash sub-menu (always available, like compress)
        AppendMenuW(sub, MF_SEPARATOR, 0, nullptr);
        {
            HMENU hashSub = CreatePopupMenu();
            AppendMenuW(hashSub, MF_STRING, idCmdFirst + CMD_HASH_XXH32, L"XXH32");
            AppendMenuW(hashSub, MF_STRING, idCmdFirst + CMD_HASH_XXH64, L"XXH64");
            AppendMenuW(hashSub, MF_STRING, idCmdFirst + CMD_HASH_CRC32, L"CRC32");
            AppendMenuW(hashSub, MF_STRING, idCmdFirst + CMD_HASH_CRC64, L"CRC64");

            MENUITEMINFOW hmi = { sizeof(hmi) };
            hmi.fMask      = MIIM_SUBMENU | MIIM_STRING | MIIM_ID;
            hmi.wID        = idCmdFirst + CMD_HASH_XXH32; // any valid id in range; submenu never invokes
            hmi.hSubMenu   = hashSub;
            hmi.dwTypeData = const_cast<wchar_t*>(L"Hash");
            InsertMenuItemW(sub, GetMenuItemCount(sub), TRUE, &hmi);
        }

        MENUITEMINFOW mii = { sizeof(mii) };
        mii.fMask    = MIIM_SUBMENU | MIIM_STRING | MIIM_ID;
        mii.wID      = idCmdFirst + CMD_PARENT;
        mii.hSubMenu = sub;
        mii.dwTypeData = const_cast<wchar_t*>(L"Fox_Archiver");
        InsertMenuItemW(hMenu, indexMenu, TRUE, &mii);

        return MAKE_HRESULT(SEVERITY_SUCCESS, 0, CMD_COUNT);
    }

    IFACEMETHODIMP InvokeCommand(CMINVOKECOMMANDINFO* pici)
    {
        if (!pici) return E_INVALIDARG;
        if (HIWORD(pici->lpVerb) != 0) return E_FAIL;
        if (m_count == 0) return E_FAIL;

        UINT cmd = LOWORD(pici->lpVerb);
        if (cmd >= CMD_PARENT) return E_INVALIDARG;

        // -------------------------------------------------------------------
        // Archive actions: launch ArchiveManager.exe. No .lst file needed -
        // a single archive is one path passed directly.
        // -------------------------------------------------------------------
        if (cmd == CMD_OPENARCHIVE ||
            cmd == CMD_DECOMPRESS_HERE ||
            cmd == CMD_DECOMPRESS_TONAMED ||
            cmd == CMD_TEST_ARCHIVE)
        {
            wchar_t mgrPath[MAX_PATH];
            GetModuleDir(mgrPath, MAX_PATH);
            StringCchCatW(mgrPath, MAX_PATH, L"ArchiveManager.exe");
            if (!PathFileExistsW(mgrPath))
                return E_FAIL;

            wchar_t archiveFolder[MAX_PATH], namedFolder[MAX_PATH];
            BuildDecompressPaths(archiveFolder, MAX_PATH, namedFolder, MAX_PATH);

            wchar_t dargs[MAX_PATH * 3];

            switch (cmd)
            {
case CMD_OPENARCHIVE:
    StringCchPrintfW(dargs, ARRAYSIZE(dargs),
        L"\"%s\"", m_files[0]);
    break;

case CMD_DECOMPRESS_HERE:
    StringCchPrintfW(dargs, ARRAYSIZE(dargs),
        L"\"%s\" \"%s\" --quick", m_files[0], archiveFolder);
    break;

case CMD_DECOMPRESS_TONAMED:
    StringCchPrintfW(dargs, ARRAYSIZE(dargs),
        L"\"%s\" \"%s\" --quick", m_files[0], namedFolder);
    break;

case CMD_TEST_ARCHIVE:
    StringCchPrintfW(dargs, ARRAYSIZE(dargs),
        L"\"%s\" --test", m_files[0]);
    break;
            }

            SHELLEXECUTEINFOW dsei = { sizeof(dsei) };
            dsei.fMask  = 0;
            dsei.hwnd   = pici->hwnd;
            dsei.lpVerb = L"open";
            dsei.lpFile = mgrPath;
            dsei.lpParameters = dargs;
            dsei.nShow  = SW_SHOWNORMAL;

            return ShellExecuteExW(&dsei) ? S_OK : E_FAIL;
        }

       // -------------------------------------------------------------------
        // -------------------------------------------------------------------
        // List-based actions: compression and hashing write the selection
        // to a .lst file and launch the appropriate executable.
        // -------------------------------------------------------------------
        wchar_t listFile[MAX_PATH];
        if (!WriteListFile(m_files, m_count, listFile, MAX_PATH))
            return E_FAIL;

        // Compression -> Fox_Archiver.exe
        // Hashing    -> HashViewer.exe
        const wchar_t* exeName;

        if (cmd == CMD_HASH_XXH32 ||
            cmd == CMD_HASH_XXH64 ||
            cmd == CMD_HASH_CRC32 ||
            cmd == CMD_HASH_CRC64)
        {
            exeName = L"HashViewer.exe";
        }
        else
        {
            exeName = L"Fox_Archiver.exe";
        }

        wchar_t exePath[MAX_PATH];
        GetModuleDir(exePath, MAX_PATH);
        StringCchCatW(exePath, MAX_PATH, exeName);

        if (!PathFileExistsW(exePath))
        {
            DeleteFileW(listFile);
            return E_FAIL;
        }

        wchar_t outPath[MAX_PATH];
        wchar_t args[MAX_PATH * 3];

        switch (cmd)
        {
        case CMD_ADDTOARCHIVE:
            // No target/quick: open the GUI, user chooses everything.
            StringCchPrintfW(args, ARRAYSIZE(args),
                L"-form=3 --add-to-archive-list \"%s\"", listFile);
            break;

        case CMD_ADDTONAMEDARC:
            BuildOutputPath(L"fxa", outPath, MAX_PATH);
            StringCchPrintfW(args, ARRAYSIZE(args),
                L"--add-to-archive-list \"%s\" --target-ext fxa --quick \"%s\"",
                listFile, outPath);
            break;

        case CMD_ADDTONAMED7Z:
            BuildOutputPath(L"7z", outPath, MAX_PATH);
            StringCchPrintfW(args, ARRAYSIZE(args),
                L"--add-to-archive-list \"%s\" --target-ext 7z --quick \"%s\"",
                listFile, outPath);
            break;

        case CMD_ADDTONAMEDSTORE:
            // Store = .arc container in store mode.
            BuildOutputPath(L"fxa", outPath, MAX_PATH);
            StringCchPrintfW(args, ARRAYSIZE(args),
                L"--add-to-archive-list \"%s\" --target-ext store --quick \"%s\"",
                listFile, outPath);
            break;

        case CMD_HASH_XXH32:
        case CMD_HASH_XXH64:
        case CMD_HASH_CRC32:
        case CMD_HASH_CRC64:
        {
            const wchar_t* algo;

            if (cmd == CMD_HASH_XXH32)
                algo = L"xxh32";
            else if (cmd == CMD_HASH_XXH64)
                algo = L"xxh64";
            else if (cmd == CMD_HASH_CRC32)
                algo = L"crc32";
            else
                algo = L"crc64";

            StringCchPrintfW(args, ARRAYSIZE(args),
                L"--hash-list \"%s\" --hash-algo %s",
                listFile, algo);
            break;
        }

        default:
            DeleteFileW(listFile);
            return E_INVALIDARG;
        }

        SHELLEXECUTEINFOW sei = { sizeof(sei) };
        sei.fMask = 0;
        sei.hwnd = pici->hwnd;
        sei.lpVerb = L"open";
        sei.lpFile = exePath;
        sei.lpParameters = args;
        sei.nShow = SW_SHOWNORMAL;

        if (!ShellExecuteExW(&sei))
        {
            DeleteFileW(listFile);
            return E_FAIL;
        }

        // The launched application is responsible for deleting listFile
        // after it has loaded the selection.
        return S_OK;

 }




    IFACEMETHODIMP GetCommandString(UINT_PTR idCmd, UINT uType, UINT*,
                                    LPSTR pszName, UINT cchMax)
    {
        static const wchar_t* verbs[CMD_COUNT] = {
            L"addtoarchive", L"addtonamedarc", L"addtonamed7z", L"addtonamedstore",
            L"openarchive", L"decompresshere", L"decompresstonamed",
            L"testarchive",
            L"hashxxh32", L"hashxxh64", L"hashcrc32", L"hashcrc64",
            L"foxarchiver"
        };
        static const wchar_t* help[CMD_COUNT] = {
            L"Add the selected items to an archive",
            L"Add the selected items to a new .fxa archive named after them",
            L"Add the selected items to a new .7z archive named after them",
            L"Store the selected items without compression",
            L"Open and browse this archive",
            L"Extract this archive into the current folder",
            L"Extract this archive into a folder named after it",
            L"Test the integrity of this archive",
            L"Compute XXH32 hash of the selection",
            L"Compute XXH64 hash of the selection",
            L"Compute CRC32 hash of the selection",
            L"Compute CRC64 hash of the selection",
            L"fox_archiver actions"
        };
        if (idCmd >= CMD_COUNT) return E_INVALIDARG;

        switch (uType)
        {
        case GCS_VERBW:
            return StringCchCopyW((wchar_t*)pszName, cchMax, verbs[idCmd]);
        case GCS_HELPTEXTW:
            return StringCchCopyW((wchar_t*)pszName, cchMax, help[idCmd]);
        case GCS_VERBA:
            WideCharToMultiByte(CP_ACP,0,verbs[idCmd],-1,pszName,cchMax,nullptr,nullptr);
            return S_OK;
        case GCS_HELPTEXTA:
            WideCharToMultiByte(CP_ACP,0,help[idCmd],-1,pszName,cchMax,nullptr,nullptr);
            return S_OK;
        case GCS_VALIDATEA:
        case GCS_VALIDATEW:
            return S_OK;
        }
        return E_NOTIMPL;
    }

    // IContextMenu2 / IContextMenu3 - stubs are fine for a static submenu
    IFACEMETHODIMP HandleMenuMsg(UINT, WPARAM, LPARAM) { return S_OK; }
    IFACEMETHODIMP HandleMenuMsg2(UINT, WPARAM, LPARAM, LRESULT*) { return S_OK; }

private:
    void FreeFiles()
    {
        if (m_files)
        {
            for (UINT i = 0; i < m_count; ++i) delete[] m_files[i];
            delete[] m_files;
            m_files = nullptr;
        }
        m_count = 0;
    }

    void BuildBaseName(wchar_t* out, size_t cch)
    {
        if (m_count == 1)
        {
            // filename without extension
            const wchar_t* fn = PathFindFileNameW(m_files[0]);
            StringCchCopyW(out, cch, fn);
            PathRemoveExtensionW(out);
        }
        else
        {
            // name of the containing folder
            wchar_t dir[MAX_PATH];
            StringCchCopyW(dir, MAX_PATH, m_files[0]);
            PathRemoveFileSpecW(dir);
            StringCchCopyW(out, cch, PathFindFileNameW(dir));
        }
    }

    // True only for a single selected file whose extension is a known archive.
    bool SelectionIsArchive()
    {
        if (m_count != 1) return false;
        const wchar_t* ext = PathFindExtensionW(m_files[0]); // ".arc", ".7z", ...
        if (!ext || !*ext) return false;
        return (_wcsicmp(ext, L".fxa") == 0) ||
               (_wcsicmp(ext, L".7z")  == 0) ||
               (_wcsicmp(ext, L".zip") == 0);
    }

    // archiveFolder -> the folder the archive lives in (decompress here)
    // namedFolder   -> archiveFolder\<basename-without-ext> (decompress to)
    void BuildDecompressPaths(wchar_t* archiveFolder, size_t cchFolder,
                              wchar_t* namedFolder,   size_t cchNamed)
    {
        StringCchCopyW(archiveFolder, cchFolder, m_files[0]);
        PathRemoveFileSpecW(archiveFolder);

        wchar_t base[MAX_PATH];
        StringCchCopyW(base, MAX_PATH, PathFindFileNameW(m_files[0]));
        PathRemoveExtensionW(base);

        StringCchPrintfW(namedFolder, cchNamed, L"%s\\%s", archiveFolder, base);
    }

    void BuildOutputPath(const wchar_t* ext, wchar_t* out, size_t cch)
    {
        wchar_t baseName[MAX_PATH];
        BuildBaseName(baseName, MAX_PATH);

        wchar_t dir[MAX_PATH];
        StringCchCopyW(dir, MAX_PATH, m_files[0]);
        PathRemoveFileSpecW(dir); // parent folder of the first item

        StringCchPrintfW(out, cch, L"%s\\%s.%s", dir, baseName, ext);
    }

    LONG      m_cRef;
    wchar_t** m_files;
    UINT      m_count;
};

// ---------------------------------------------------------------------------
// Class factory
// ---------------------------------------------------------------------------
class FoxFactory : public IClassFactory
{
public:
    FoxFactory() : m_cRef(1) { InterlockedIncrement(&g_cRefDll); }
    ~FoxFactory() { InterlockedDecrement(&g_cRefDll); }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv)
    {
        if (riid == IID_IUnknown || riid == IID_IClassFactory)
        {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&m_cRef); }
    IFACEMETHODIMP_(ULONG) Release()
    {
        ULONG c = InterlockedDecrement(&m_cRef);
        if (c == 0) delete this;
        return c;
    }
    IFACEMETHODIMP CreateInstance(IUnknown* pOuter, REFIID riid, void** ppv)
    {
        if (pOuter) return CLASS_E_NOAGGREGATION;
        FoxCtxMenu* obj = new (std::nothrow) FoxCtxMenu();
        if (!obj) return E_OUTOFMEMORY;
        HRESULT hr = obj->QueryInterface(riid, ppv);
        obj->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL fLock)
    {
        if (fLock) InterlockedIncrement(&g_cRefDll);
        else       InterlockedDecrement(&g_cRefDll);
        return S_OK;
    }
private:
    LONG m_cRef;
};

// ---------------------------------------------------------------------------
// DLL exports
// ---------------------------------------------------------------------------
STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv)
{
    if (rclsid != CLSID_FoxArchiverCtxMenu)
        return CLASS_E_CLASSNOTAVAILABLE;
    FoxFactory* f = new (std::nothrow) FoxFactory();
    if (!f) return E_OUTOFMEMORY;
    HRESULT hr = f->QueryInterface(riid, ppv);
    f->Release();
    return hr;
}

STDAPI DllCanUnloadNow()
{
    return (g_cRefDll == 0) ? S_OK : S_FALSE;
}

static bool SetReg(HKEY root, const wchar_t* subkey, const wchar_t* valName, const wchar_t* data)
{
    HKEY hk;
    if (RegCreateKeyExW(root, subkey, 0, nullptr, 0, KEY_WRITE | KEY_WOW64_64KEY,
                        nullptr, &hk, nullptr) != ERROR_SUCCESS)
        return false;
    LONG r = RegSetValueExW(hk, valName, 0, REG_SZ,
                            (const BYTE*)data, (DWORD)((wcslen(data) + 1) * sizeof(wchar_t)));
    RegCloseKey(hk);
    return r == ERROR_SUCCESS;
}

STDAPI DllRegisterServer()
{
    wchar_t dllPath[MAX_PATH];
    GetModuleFileNameW(g_hInst, dllPath, MAX_PATH);

    wchar_t key[512];

    // CLSID\{..}
    StringCchPrintfW(key, 512, L"CLSID\\%s", kClsidString);
    if (!SetReg(HKEY_CLASSES_ROOT, key, nullptr, kFriendly)) return E_ACCESSDENIED;

    // CLSID\{..}\InprocServer32 = dll path, ThreadingModel = Apartment
    StringCchPrintfW(key, 512, L"CLSID\\%s\\InprocServer32", kClsidString);
    SetReg(HKEY_CLASSES_ROOT, key, nullptr, dllPath);
    SetReg(HKEY_CLASSES_ROOT, key, L"ThreadingModel", L"Apartment");

    // *\shellex\ContextMenuHandlers\Fox_Archiver = {clsid}
    StringCchPrintfW(key, 512, L"*\\shellex\\ContextMenuHandlers\\%s", kVerbName);
    SetReg(HKEY_CLASSES_ROOT, key, nullptr, kClsidString);

    // Directory\shellex\ContextMenuHandlers\Fox_Archiver = {clsid}
    StringCchPrintfW(key, 512, L"Directory\\shellex\\ContextMenuHandlers\\%s", kVerbName);
    SetReg(HKEY_CLASSES_ROOT, key, nullptr, kClsidString);

    // HKLM Approved
    SetReg(HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Shell Extensions\\Approved",
        kClsidString, kVerbName);

    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
    return S_OK;
}

STDAPI DllUnregisterServer()
{
    wchar_t key[512];

    StringCchPrintfW(key, 512, L"*\\shellex\\ContextMenuHandlers\\%s", kVerbName);
    RegDeleteKeyExW(HKEY_CLASSES_ROOT, key, KEY_WOW64_64KEY, 0);

    StringCchPrintfW(key, 512, L"Directory\\shellex\\ContextMenuHandlers\\%s", kVerbName);
    RegDeleteKeyExW(HKEY_CLASSES_ROOT, key, KEY_WOW64_64KEY, 0);

    StringCchPrintfW(key, 512, L"CLSID\\%s\\InprocServer32", kClsidString);
    RegDeleteKeyExW(HKEY_CLASSES_ROOT, key, KEY_WOW64_64KEY, 0);
    StringCchPrintfW(key, 512, L"CLSID\\%s", kClsidString);
    RegDeleteKeyExW(HKEY_CLASSES_ROOT, key, KEY_WOW64_64KEY, 0);

    HKEY hk;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
            L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Shell Extensions\\Approved",
            0, KEY_WRITE | KEY_WOW64_64KEY, &hk) == ERROR_SUCCESS)
    {
        RegDeleteValueW(hk, kClsidString);
        RegCloseKey(hk);
    }

    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
    return S_OK;
}

BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_hInst = hInst;
        DisableThreadLibraryCalls(hInst);
    }
    return TRUE;
}