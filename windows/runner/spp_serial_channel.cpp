#include "spp_serial_channel.h"

#include <windows.h>

#include <setupapi.h>
#include <devguid.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "setupapi.lib")

namespace {

constexpr char kMethodChannel[] = "com.cbstudio.telltale/spp_serial";
constexpr char kEventChannel[] = "com.cbstudio.telltale/spp_serial/inbound";

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       utf8.data(),
                                       static_cast<int>(utf8.size()), nullptr,
                                       0);
  if (size <= 0) return {};
  std::wstring wide(static_cast<size_t>(size), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                          static_cast<int>(utf8.size()), wide.data(), size) <=
      0) {
    return {};
  }
  return wide;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                          static_cast<int>(wide.size()), nullptr, 0, nullptr,
                          nullptr);
  if (size <= 0) return {};
  std::string utf8(static_cast<size_t>(size), '\0');
  if (WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                          static_cast<int>(wide.size()), utf8.data(), size,
                          nullptr, nullptr) <= 0) {
    return {};
  }
  return utf8;
}

bool LooksLikeBluetoothSerial(const std::wstring& friendly,
                              const std::wstring& hardware) {
  auto has = [](const std::wstring& hay, const wchar_t* needle) {
    return hay.find(needle) != std::wstring::npos;
  };
  // Bluetooth SPP COM ports after pairing typically carry BTHENUM / BthModem
  // in the hardware id, or "Bluetooth" / "Standard Serial over Bluetooth"
  // in the friendly name. Do not offer arbitrary USB-UART COMx as Classic.
  if (has(hardware, L"BTHENUM") || has(hardware, L"BthModem") ||
      has(hardware, L"BTHPORT")) {
    return true;
  }
  if (has(friendly, L"Bluetooth") || has(friendly, L"bluetooth")) {
    return true;
  }
  return false;
}

std::wstring ReadDeviceRegistryPortName(HDEVINFO info,
                                        SP_DEVINFO_DATA* data) {
  HKEY key = SetupDiOpenDevRegKey(info, data, DICS_FLAG_GLOBAL, 0,
                                  DIREG_DEV, KEY_READ);
  if (key == INVALID_HANDLE_VALUE) {
    return {};
  }
  wchar_t buffer[64] = {};
  DWORD type = 0;
  DWORD size = sizeof(buffer);
  const LONG status =
      RegQueryValueExW(key, L"PortName", nullptr, &type,
                       reinterpret_cast<LPBYTE>(buffer), &size);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ)) {
    return {};
  }
  return buffer;
}

std::wstring ReadProperty(HDEVINFO info, SP_DEVINFO_DATA* data, DWORD prop) {
  DWORD size = 0;
  SetupDiGetDeviceRegistryPropertyW(info, data, prop, nullptr, nullptr, 0,
                                    &size);
  if (size == 0) return {};
  std::wstring buffer(size / sizeof(wchar_t), L'\0');
  if (!SetupDiGetDeviceRegistryPropertyW(
          info, data, prop, nullptr,
          reinterpret_cast<PBYTE>(buffer.data()), size, nullptr)) {
    return {};
  }
  // MULTI_SZ / SZ may include trailing nulls.
  while (!buffer.empty() && buffer.back() == L'\0') {
    buffer.pop_back();
  }
  // For MULTI_SZ hardware ids, keep the first entry only for matching, but
  // pass the joined view when useful — replace interior nulls with ';'.
  for (auto& ch : buffer) {
    if (ch == L'\0') ch = L';';
  }
  return buffer;
}

flutter::EncodableList EnumerateBluetoothSppPorts() {
  flutter::EncodableList ports;
  HDEVINFO info = SetupDiGetClassDevsW(&GUID_DEVCLASS_PORTS, nullptr, nullptr,
                                       DIGCF_PRESENT);
  if (info == INVALID_HANDLE_VALUE) {
    return ports;
  }

  SP_DEVINFO_DATA data{};
  data.cbSize = sizeof(data);
  for (DWORD index = 0; SetupDiEnumDeviceInfo(info, index, &data); ++index) {
    const std::wstring friendly =
        ReadProperty(info, &data, SPDRP_FRIENDLYNAME);
    const std::wstring hardware =
        ReadProperty(info, &data, SPDRP_HARDWAREID);
    if (!LooksLikeBluetoothSerial(friendly, hardware)) {
      continue;
    }
    std::wstring port = ReadDeviceRegistryPortName(info, &data);
    if (port.empty()) {
      // Fallback: "(COM12)" at the end of the friendly name.
      const auto open = friendly.rfind(L"(COM");
      const auto close = friendly.rfind(L')');
      if (open != std::wstring::npos && close != std::wstring::npos &&
          close > open) {
        port = friendly.substr(open + 1, close - open - 1);
      }
    }
    if (port.empty() || port.rfind(L"COM", 0) != 0) {
      continue;
    }
    flutter::EncodableMap entry;
    entry[flutter::EncodableValue("portName")] =
        flutter::EncodableValue(WideToUtf8(port));
    entry[flutter::EncodableValue("friendlyName")] =
        flutter::EncodableValue(WideToUtf8(friendly.empty() ? port : friendly));
    if (!hardware.empty()) {
      entry[flutter::EncodableValue("hardwareId")] =
          flutter::EncodableValue(WideToUtf8(hardware));
    }
    ports.push_back(flutter::EncodableValue(entry));
  }
  SetupDiDestroyDeviceInfoList(info);
  return ports;
}

}  // namespace

// EventSink posts outlive Impl when the window tears down with tasks still
// queued on the platform thread. Shared delivery state keeps those lambdas
// from touching a destroyed Impl.
struct SppDeliveryState {
  std::mutex mutex;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink;
  std::atomic<uint64_t> open_generation{0};
};

class SppSerialChannel::Impl {
 public:
  explicit Impl(flutter::FlutterEngine* engine)
      : engine_(engine), delivery_(std::make_shared<SppDeliveryState>()) {
    auto* messenger = engine_->messenger();
    method_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            messenger, kMethodChannel,
            &flutter::StandardMethodCodec::GetInstance());
    method_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) { HandleMethod(call, std::move(result)); });

    event_channel_ =
        std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
            messenger, kEventChannel,
            &flutter::StandardMethodCodec::GetInstance());
    std::weak_ptr<SppDeliveryState> weak_delivery = delivery_;
    event_channel_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
            [weak_delivery](
                const flutter::EncodableValue*,
                std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                    sink)
                -> std::unique_ptr<
                    flutter::StreamHandlerError<flutter::EncodableValue>> {
              if (auto delivery = weak_delivery.lock()) {
                std::lock_guard<std::mutex> lock(delivery->mutex);
                delivery->sink = std::move(sink);
              }
              return nullptr;
            },
            [weak_delivery](const flutter::EncodableValue*)
                -> std::unique_ptr<
                    flutter::StreamHandlerError<flutter::EncodableValue>> {
              if (auto delivery = weak_delivery.lock()) {
                std::lock_guard<std::mutex> lock(delivery->mutex);
                delivery->sink.reset();
              }
              return nullptr;
            }));
  }

  ~Impl() {
    ClosePort();
    // Drop the sink while delivery_ may still be held by queued tasks; those
    // tasks no-op once sink is null / generation advanced.
    std::lock_guard<std::mutex> lock(delivery_->mutex);
    delivery_->sink.reset();
  }

 private:
  void HandleMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto& method = call.method_name();
    if (method == "listPorts") {
      result->Success(flutter::EncodableValue(EnumerateBluetoothSppPorts()));
      return;
    }
    if (method == "open") {
      OpenPort(call.arguments(), std::move(result));
      return;
    }
    if (method == "write") {
      WritePort(call.arguments(), std::move(result));
      return;
    }
    if (method == "close") {
      ClosePort();
      result->Success();
      return;
    }
    result->NotImplemented();
  }

  void OpenPort(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto* map = std::get_if<flutter::EncodableMap>(arguments);
    if (map == nullptr) {
      result->Error("invalid_args", "open requires a map");
      return;
    }
    const auto port_it = map->find(flutter::EncodableValue("portName"));
    if (port_it == map->end()) {
      result->Error("invalid_args", "portName required");
      return;
    }
    const auto* port_utf8 = std::get_if<std::string>(&port_it->second);
    if (port_utf8 == nullptr || port_utf8->empty()) {
      result->Error("invalid_args", "portName required");
      return;
    }
    int baud = 38400;
    const auto baud_it = map->find(flutter::EncodableValue("baudRate"));
    if (baud_it != map->end()) {
      if (const auto* b = std::get_if<int32_t>(&baud_it->second)) {
        baud = *b;
      } else if (const auto* b64 = std::get_if<int64_t>(&baud_it->second)) {
        baud = static_cast<int>(*b64);
      }
    }

    ClosePort();

    const std::wstring path = L"\\\\.\\" + Utf8ToWide(*port_utf8);
    HANDLE handle =
        CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
      result->Error("open_failed", "CreateFileW failed",
                    flutter::EncodableValue(static_cast<int64_t>(GetLastError())));
      return;
    }

    DCB dcb{};
    dcb.DCBlength = sizeof(dcb);
    if (!GetCommState(handle, &dcb)) {
      CloseHandle(handle);
      result->Error("open_failed", "GetCommState failed");
      return;
    }
    dcb.BaudRate = static_cast<DWORD>(baud);
    dcb.ByteSize = 8;
    dcb.Parity = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    dcb.fBinary = TRUE;
    // ELM327 SPP links are raw 38400 8N1. Inherited CTS/DSR/XON settings from a
    // previous Windows COM config can stall writes even when baud looks right.
    dcb.fOutxCtsFlow = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fDsrSensitivity = FALSE;
    dcb.fTXContinueOnXoff = FALSE;
    dcb.fOutX = FALSE;
    dcb.fInX = FALSE;
    dcb.fDtrControl = DTR_CONTROL_ENABLE;
    dcb.fRtsControl = RTS_CONTROL_ENABLE;
    if (!SetCommState(handle, &dcb)) {
      CloseHandle(handle);
      result->Error("open_failed", "SetCommState failed");
      return;
    }

    COMMTIMEOUTS timeouts{};
    // Return promptly when no bytes are waiting so disconnect can unwind.
    timeouts.ReadIntervalTimeout = 50;
    timeouts.ReadTotalTimeoutMultiplier = 0;
    timeouts.ReadTotalTimeoutConstant = 50;
    timeouts.WriteTotalTimeoutMultiplier = 0;
    timeouts.WriteTotalTimeoutConstant = 2000;
    if (!SetCommTimeouts(handle, &timeouts)) {
      CloseHandle(handle);
      result->Error("open_failed", "SetCommTimeouts failed");
      return;
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      handle_ = handle;
      reading_ = true;
      // New open invalidates any platform-thread posts still queued from a
      // prior ReadLoop so they cannot touch the EventSink after reopen.
      delivery_->open_generation.fetch_add(1);
    }
    const uint64_t generation = delivery_->open_generation.load();
    read_thread_ = std::thread([this, generation]() { ReadLoop(generation); });
    result->Success();
  }

  void WritePort(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto* map = std::get_if<flutter::EncodableMap>(arguments);
    if (map == nullptr) {
      result->Error("invalid_args", "write requires a map");
      return;
    }
    const auto bytes_it = map->find(flutter::EncodableValue("bytes"));
    if (bytes_it == map->end()) {
      result->Error("invalid_args", "bytes required");
      return;
    }
    const auto* bytes =
        std::get_if<std::vector<uint8_t>>(&bytes_it->second);
    if (bytes == nullptr) {
      result->Error("invalid_args", "bytes must be a Uint8List");
      return;
    }

    HANDLE handle = INVALID_HANDLE_VALUE;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      handle = handle_;
    }
    if (handle == INVALID_HANDLE_VALUE) {
      result->Error("not_open", "Port is not open");
      return;
    }
    DWORD written_total = 0;
    while (written_total < bytes->size()) {
      DWORD written = 0;
      if (!WriteFile(handle, bytes->data() + written_total,
                     static_cast<DWORD>(bytes->size() - written_total),
                     &written, nullptr)) {
        result->Error(
            "write_failed", "WriteFile failed",
            flutter::EncodableValue(static_cast<int64_t>(GetLastError())));
        return;
      }
      if (written == 0) {
        result->Error("write_failed", "WriteFile wrote zero bytes");
        return;
      }
      written_total += written;
    }
    result->Success();
  }

  void ClosePort() {
    // Bump generation before joining so any already-queued platform tasks from
    // this open are dropped, mirroring Linux RFCOMM open_generation.
    delivery_->open_generation.fetch_add(1);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      reading_ = false;
      if (handle_ != INVALID_HANDLE_VALUE) {
        CancelIoEx(handle_, nullptr);
        CloseHandle(handle_);
        handle_ = INVALID_HANDLE_VALUE;
      }
    }
    if (read_thread_.joinable()) {
      read_thread_.join();
    }
  }

  void PostBytes(uint64_t generation, std::vector<uint8_t> chunk) {
    // Capture shared delivery — not `this` — so a queued task can outlive
    // FlutterWindow teardown without use-after-free.
    auto delivery = delivery_;
    engine_->PostPlatformThreadTask(
        [delivery, generation, chunk = std::move(chunk)]() mutable {
          std::lock_guard<std::mutex> lock(delivery->mutex);
          if (generation != delivery->open_generation.load() ||
              delivery->sink == nullptr) {
            return;
          }
          delivery->sink->Success(flutter::EncodableValue(chunk));
        });
  }

  void PostReadError(uint64_t generation, DWORD err) {
    auto delivery = delivery_;
    engine_->PostPlatformThreadTask([delivery, generation, err]() {
      std::lock_guard<std::mutex> lock(delivery->mutex);
      if (generation != delivery->open_generation.load() ||
          delivery->sink == nullptr) {
        return;
      }
      // EventSink::Error takes const T&, not a pointer (unlike
      // MethodResult::Error's optional details overload).
      delivery->sink->Error(
          "read_failed", "ReadFile failed",
          flutter::EncodableValue(static_cast<int64_t>(err)));
    });
  }

  void ReadLoop(uint64_t generation) {
    std::vector<uint8_t> buffer(512);
    while (true) {
      HANDLE handle = INVALID_HANDLE_VALUE;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!reading_) break;
        handle = handle_;
      }
      if (handle == INVALID_HANDLE_VALUE) break;

      DWORD read = 0;
      const BOOL ok =
          ReadFile(handle, buffer.data(),
                   static_cast<DWORD>(buffer.size()), &read, nullptr);
      if (!ok) {
        const DWORD err = GetLastError();
        if (err == ERROR_OPERATION_ABORTED || err == ERROR_INVALID_HANDLE) {
          // Expected during ClosePort / CancelIoEx — unwind quietly.
          break;
        }
        // With COMMTIMEOUTS above, idle reads succeed with zero bytes.
        // Any other ReadFile failure is permanent (device unplugged /
        // ERROR_DEVICE_NOT_CONNECTED / ERROR_GEN_FAILURE, …). Retrying
        // would spin a core and never tell SerialTransport the link died.
        {
          std::lock_guard<std::mutex> lock(mutex_);
          reading_ = false;
        }
        PostReadError(generation, err);
        break;
      }
      if (read == 0) continue;

      std::vector<uint8_t> chunk(
          buffer.begin(),
          buffer.begin() + static_cast<std::ptrdiff_t>(read));
      PostBytes(generation, std::move(chunk));
    }
  }

  flutter::FlutterEngine* engine_;
  std::shared_ptr<SppDeliveryState> delivery_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::mutex mutex_;
  HANDLE handle_ = INVALID_HANDLE_VALUE;
  std::thread read_thread_;
  bool reading_ = false;
};

SppSerialChannel::SppSerialChannel(flutter::FlutterEngine* engine)
    : impl_(std::make_unique<Impl>(engine)) {}

SppSerialChannel::~SppSerialChannel() = default;
