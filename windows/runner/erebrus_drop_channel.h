#ifndef RUNNER_EREBRUS_DROP_CHANNEL_H_
#define RUNNER_EREBRUS_DROP_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

#include <functional>

// Registers the Windows side of the "com.erebrus.drop/network" method channel.
//
// Channel contract (must stay in sync with the Android, iOS and macOS
// implementations, and with NativeFilePickerService in
// lib/features/join/native_file_picker_service.dart):
//
//   method:  "pickFilesForUpload"
//   args:    none
//   returns: a list of maps, one per selected file, each shaped as
//              {
//                "path":      String,  // absolute filesystem path
//                "name":      String,  // file name including extension
//                "sizeBytes": int,     // 64-bit file size, 0 if unknown
//              }
//            The user cancelling the dialog is not an error: an empty list is
//            returned, which Dart treats as "nothing picked".
//   errors:  FlutterError with code "PICK_FILE_UNAVAILABLE" when the shell
//            dialog cannot be created, or "PICK_FILE_FAILED" when reading the
//            selection fails. Details carry the failing HRESULT.
//
//   method:  "selectHostFolder"
//   args:    none
//   returns: a map describing the folder to host files from:
//              {
//                "name":     String,  // folder name, "Selected folder" for a
//                                     // drive root such as "D:\"
//                "uri":      String,  // bare absolute path, e.g. "C:\Drop";
//                                     // DesktopHostFolder resolves this with
//                                     // Directory(), so it is deliberately
//                                     // not a file:// URI
//                "platform": String,  // "Windows", alongside "macOS",
//                                     // "iOS Files" and "Android SAF"
//              }
//            No "bookmark" key: that is macOS security-scoped bookmark data,
//            and Dart only calls restoreHostFolderAccess on macOS.
//            Cancelling returns null, which Dart reads as "nothing selected".
//   errors:  FlutterError with code "PICK_FOLDER_FAILED". Note that
//            "PICK_FOLDER_UNAVAILABLE" is reserved: Dart synthesizes it when
//            no native handler is registered at all.
//
// Any other method on this channel is answered with notImplemented, matching
// the behaviour before this handler existed. In particular
// restoreHostFolderAccess and releaseHostFolderAccess are macOS-only, and
// syncShareIntakeHostFolder / clearShareIntakeHostFolder are ignored by Dart
// when unimplemented.
//
// |owner_window_provider| is queried lazily each time a dialog is opened so
// that the picker is modal to the current Flutter window (it may return nullptr
// once the window is gone, in which case the dialog is shown unowned).
void RegisterErebrusDropChannel(flutter::FlutterEngine* engine,
                                std::function<HWND()> owner_window_provider);

#endif  // RUNNER_EREBRUS_DROP_CHANNEL_H_
