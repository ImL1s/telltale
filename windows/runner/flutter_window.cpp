#include "flutter_window.h"

#include <optional>
#include <string>

#include <windows.h>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "spp_serial_channel.h"

namespace {

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       utf8.data(),
                                       static_cast<int>(utf8.size()), nullptr,
                                       0);
  if (size <= 0) {
    return {};
  }
  std::wstring wide(static_cast<size_t>(size), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                          static_cast<int>(utf8.size()), wide.data(),
                          size) <= 0) {
    return {};
  }
  return wide;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  capacity_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.cbstudio.telltale/app_storage_capacity",
          &flutter::StandardMethodCodec::GetInstance());
  capacity_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "getAvailableBytes") {
          result->NotImplemented();
          return;
        }
        // Probe the volume that owns the Dart share-cache directory, not
        // %TEMP% — enterprise profiles often redirect TEMP to another drive.
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("capacity_failed", "Cache path required");
          return;
        }
        const auto path_it = arguments->find(flutter::EncodableValue("path"));
        if (path_it == arguments->end()) {
          result->Error("capacity_failed", "Cache path required");
          return;
        }
        const auto* path_utf8 = std::get_if<std::string>(&path_it->second);
        if (path_utf8 == nullptr || path_utf8->empty()) {
          result->Error("capacity_failed", "Cache path required");
          return;
        }
        const std::wstring path = Utf8ToWide(*path_utf8);
        if (path.empty()) {
          result->Error("capacity_failed", "Cache path encoding failed");
          return;
        }
        ULARGE_INTEGER available{};
        if (!GetDiskFreeSpaceExW(path.c_str(), &available, nullptr, nullptr) ||
            available.QuadPart == 0) {
          result->Error("capacity_invalid",
                        "Available bytes were not positive");
          return;
        }
        result->Success(flutter::EncodableValue(
            static_cast<int64_t>(available.QuadPart)));
      });

  spp_serial_channel_ =
      std::make_unique<SppSerialChannel>(flutter_controller_->engine());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  spp_serial_channel_.reset();
  capacity_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
