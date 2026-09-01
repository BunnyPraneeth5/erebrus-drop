#include "erebrus_drop_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <shobjidl.h>

#include <memory>
#include <string>
#include <utility>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "com.erebrus.drop/network";
constexpr char kPickFilesMethod[] = "pickFilesForUpload";
constexpr char kSelectHostFolderMethod[] = "selectHostFolder";

using FlutterMethodResult = flutter::MethodResult<flutter::EncodableValue>;

// Minimal owning pointer for the COM interfaces used below, so every early
// return releases the dialog and its results.
template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  ~ComPtr() { Reset(); }
  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;

  T** Receive() { return &pointer_; }
  T* operator->() const { return pointer_; }
  T* Get() const { return pointer_; }

  void Reset() {
    if (pointer_) {
      pointer_->Release();
      pointer_ = nullptr;
    }
  }

 private:
  T* pointer_ = nullptr;
};

// Balances CoInitializeEx for the duration of a dialog. The runner already
// initializes COM on the platform thread (see main.cpp), so this usually just
// bumps the reference count.
class ScopedComInitializer {
 public:
  ScopedComInitializer() {
    const HRESULT result = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    // RPC_E_CHANGED_MODE means someone else picked a different apartment; COM
    // is usable but this instance must not uninitialize it.
    owns_initialization_ = SUCCEEDED(result);
  }

  ~ScopedComInitializer() {
    if (owns_initialization_) {
      ::CoUninitialize();
    }
  }

  ScopedComInitializer(const ScopedComInitializer&) = delete;
  ScopedComInitializer& operator=(const ScopedComInitializer&) = delete;

 private:
  bool owns_initialization_ = false;
};

std::wstring FileNameFromPath(const std::wstring& path) {
  const size_t separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return path;
  }
  return path.substr(separator + 1);
}

// Returns the file size in bytes, or 0 when the path cannot be queried or is a
// directory (the dialog is configured for files only, but be defensive).
int64_t FileSizeInBytes(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA attributes = {};
  if (!::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard,
                              &attributes)) {
    return 0;
  }
  if (attributes.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
    return 0;
  }
  ULARGE_INTEGER size = {};
  size.HighPart = attributes.nFileSizeHigh;
  size.LowPart = attributes.nFileSizeLow;
  return static_cast<int64_t>(size.QuadPart);
}

void FailWithHresult(FlutterMethodResult* result, const std::string& code,
                     const std::string& message, HRESULT hr) {
  result->Error(code, message,
                flutter::EncodableValue(static_cast<int64_t>(hr)));
}

void PickFilesForUpload(HWND owner_window, FlutterMethodResult* result) {
  ScopedComInitializer com_initializer;

  ComPtr<IFileOpenDialog> dialog;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_IFileOpenDialog,
                                  reinterpret_cast<void**>(dialog.Receive()));
  if (FAILED(hr) || dialog.Get() == nullptr) {
    FailWithHresult(result, "PICK_FILE_UNAVAILABLE",
                    "Could not open the Windows file picker.", hr);
    return;
  }

  FILEOPENDIALOGOPTIONS options = 0;
  hr = dialog->GetOptions(&options);
  if (FAILED(hr)) {
    FailWithHresult(result, "PICK_FILE_UNAVAILABLE",
                    "Could not configure the Windows file picker.", hr);
    return;
  }
  // Multi-select matches Android (EXTRA_ALLOW_MULTIPLE) and iOS
  // (allowsMultipleSelection); FORCEFILESYSTEM keeps the results to real paths
  // that Dart can hand to File().
  hr = dialog->SetOptions(options | FOS_ALLOWMULTISELECT | FOS_FILEMUSTEXIST |
                          FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
  if (FAILED(hr)) {
    FailWithHresult(result, "PICK_FILE_UNAVAILABLE",
                    "Could not configure the Windows file picker.", hr);
    return;
  }
  dialog->SetTitle(L"Select files to upload");

  hr = dialog->Show(owner_window);
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    // Cancelling is not an error: Dart reads an empty list as "nothing picked".
    result->Success(flutter::EncodableValue(flutter::EncodableList()));
    return;
  }
  if (FAILED(hr)) {
    FailWithHresult(result, "PICK_FILE_FAILED",
                    "The Windows file picker could not be shown.", hr);
    return;
  }

  ComPtr<IShellItemArray> items;
  hr = dialog->GetResults(items.Receive());
  if (FAILED(hr) || items.Get() == nullptr) {
    FailWithHresult(result, "PICK_FILE_FAILED",
                    "Could not read the selected files.", hr);
    return;
  }

  DWORD count = 0;
  hr = items->GetCount(&count);
  if (FAILED(hr)) {
    FailWithHresult(result, "PICK_FILE_FAILED",
                    "Could not read the selected files.", hr);
    return;
  }

  flutter::EncodableList picked;
  for (DWORD index = 0; index < count; index++) {
    ComPtr<IShellItem> item;
    if (FAILED(items->GetItemAt(index, item.Receive())) ||
        item.Get() == nullptr) {
      continue;
    }
    PWSTR display_path = nullptr;
    if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &display_path)) ||
        display_path == nullptr) {
      continue;
    }
    const std::wstring path(display_path);
    ::CoTaskMemFree(display_path);
    if (path.empty()) {
      continue;
    }
    picked.push_back(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("path"),
         flutter::EncodableValue(Utf8FromUtf16(path.c_str()))},
        {flutter::EncodableValue("name"),
         flutter::EncodableValue(Utf8FromUtf16(FileNameFromPath(path).c_str()))},
        {flutter::EncodableValue("sizeBytes"),
         flutter::EncodableValue(FileSizeInBytes(path))},
    }));
  }

  result->Success(flutter::EncodableValue(std::move(picked)));
}

void SelectHostFolder(HWND owner_window, FlutterMethodResult* result) {
  ScopedComInitializer com_initializer;

  ComPtr<IFileOpenDialog> dialog;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_IFileOpenDialog,
                                  reinterpret_cast<void**>(dialog.Receive()));
  if (FAILED(hr) || dialog.Get() == nullptr) {
    FailWithHresult(result, "PICK_FOLDER_FAILED",
                    "Could not open the Windows folder picker.", hr);
    return;
  }

  FILEOPENDIALOGOPTIONS options = 0;
  hr = dialog->GetOptions(&options);
  if (FAILED(hr)) {
    FailWithHresult(result, "PICK_FOLDER_FAILED",
                    "Could not configure the Windows folder picker.", hr);
    return;
  }
  // FOS_PICKFOLDERS turns the open dialog into a folder browser; a single
  // folder only, so FOS_ALLOWMULTISELECT is deliberately not set.
  hr = dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                          FOS_PATHMUSTEXIST);
  if (FAILED(hr)) {
    FailWithHresult(result, "PICK_FOLDER_FAILED",
                    "Could not configure the Windows folder picker.", hr);
    return;
  }
  dialog->SetTitle(L"Select Drop folder");
  dialog->SetOkButtonLabel(L"Select Folder");

  hr = dialog->Show(owner_window);
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    // Cancelling is not an error: Dart reads a null result as "no folder".
    result->Success();
    return;
  }
  if (FAILED(hr)) {
    FailWithHresult(result, "PICK_FOLDER_FAILED",
                    "The Windows folder picker could not be shown.", hr);
    return;
  }

  ComPtr<IShellItem> item;
  hr = dialog->GetResult(item.Receive());
  if (FAILED(hr) || item.Get() == nullptr) {
    FailWithHresult(result, "PICK_FOLDER_FAILED",
                    "Could not read the selected folder.", hr);
    return;
  }

  PWSTR display_path = nullptr;
  hr = item->GetDisplayName(SIGDN_FILESYSPATH, &display_path);
  if (FAILED(hr) || display_path == nullptr) {
    FailWithHresult(result, "PICK_FOLDER_FAILED",
                    "The selected folder has no filesystem path.", hr);
    return;
  }
  const std::wstring path(display_path);
  ::CoTaskMemFree(display_path);
  if (path.empty()) {
    // Treated as a cancellation rather than an error: Dart would reject an
    // empty uri anyway, and there is nothing the user could act on.
    result->Success();
    return;
  }

  // A drive root such as "D:\" has no trailing component to name it after;
  // macOS applies the same "Selected folder" fallback for an empty
  // lastPathComponent.
  std::wstring name = FileNameFromPath(path);
  if (name.empty()) {
    name = L"Selected folder";
  }

  // "uri" is a bare Windows path, not a file:// URI: DesktopHostFolder feeds it
  // straight to Directory(), which avoids any percent-encoding round trip.
  result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("name"),
       flutter::EncodableValue(Utf8FromUtf16(name.c_str()))},
      {flutter::EncodableValue("uri"),
       flutter::EncodableValue(Utf8FromUtf16(path.c_str()))},
      {flutter::EncodableValue("platform"), flutter::EncodableValue("Windows")},
  }));
}

}  // namespace

void RegisterErebrusDropChannel(flutter::FlutterEngine* engine,
                                std::function<HWND()> owner_window_provider) {
  if (engine == nullptr) {
    return;
  }
  // Owned for the process lifetime: the channel must outlive this call so the
  // handler stays registered.
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [owner_window_provider = std::move(owner_window_provider)](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<FlutterMethodResult> result) {
        // Both dialogs are modal and run on the platform thread, so they
        // cannot be re-entered while one is open.
        const HWND owner =
            owner_window_provider ? owner_window_provider() : nullptr;
        if (call.method_name() == kPickFilesMethod) {
          PickFilesForUpload(owner, result.get());
          return;
        }
        if (call.method_name() == kSelectHostFolderMethod) {
          SelectHostFolder(owner, result.get());
          return;
        }
        result->NotImplemented();
      });
}
