#include "spp_serial_channel.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <string.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr char kMethodChannel[] = "com.cbstudio.telltale/spp_serial";
constexpr char kEventChannel[] = "com.cbstudio.telltale/spp_serial/inbound";

bool PathExists(const std::string& path) {
  struct stat st{};
  return stat(path.c_str(), &st) == 0;
}

bool LooksLikeBluetoothTty(const std::string& name) {
  // BlueZ RFCOMM TTYs after `rfcomm bind` / bluetoothd: /dev/rfcommN.
  if (name.rfind("rfcomm", 0) == 0) return true;

  // Some stacks expose Bluetooth serial under /sys/class/tty/<name>/device
  // with a bluetooth or rfcomm ancestor. Do not advertise plain USB-UART.
  const std::string device_link = "/sys/class/tty/" + name + "/device";
  char resolved[PATH_MAX];
  if (realpath(device_link.c_str(), resolved) == nullptr) {
    return false;
  }
  const std::string path(resolved);
  return path.find("bluetooth") != std::string::npos ||
         path.find("rfcomm") != std::string::npos ||
         path.find("hci") != std::string::npos;
}

speed_t BaudToFlag(int baud) {
  switch (baud) {
    case 9600:
      return B9600;
    case 19200:
      return B19200;
    case 38400:
      return B38400;
    case 57600:
      return B57600;
    case 115200:
      return B115200;
    default:
      return B38400;
  }
}

FlValue* EnumerateBluetoothSppPorts() {
  FlValue* ports = fl_value_new_list();
  DIR* dir = opendir("/dev");
  if (dir == nullptr) {
    return ports;
  }

  while (true) {
    errno = 0;
    dirent* entry = readdir(dir);
    if (entry == nullptr) break;
    if (entry->d_name[0] == '.') continue;
    const std::string name(entry->d_name);
    if (!LooksLikeBluetoothTty(name)) continue;
    const std::string port = "/dev/" + name;
    if (!PathExists(port)) continue;

    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(map, "portName", fl_value_new_string(port.c_str()));
    // Friendly label mirrors Windows "Bluetooth … (COMx)" so the wizard
    // recognises likely adapters without requiring BlueZ SDP here.
    const std::string friendly = "Bluetooth RFCOMM (" + port + ")";
    fl_value_set_string_take(map, "friendlyName",
                             fl_value_new_string(friendly.c_str()));
    fl_value_set_string_take(map, "hardwareId",
                             fl_value_new_string("linux-rfcomm"));
    fl_value_append_take(ports, map);
  }
  closedir(dir);
  return ports;
}

struct IdleBytes {
  SppSerialChannel* channel;
  uint64_t generation;
  std::vector<uint8_t> bytes;
};

struct IdleError {
  SppSerialChannel* channel;
  uint64_t generation;
  int err;
};

}  // namespace

struct _SppSerialChannel {
  FlMethodChannel* method_channel;
  FlEventChannel* event_channel;
  std::mutex mutex;
  int fd = -1;
  std::atomic<bool> reading{false};
  std::atomic<bool> listening{false};
  // Bumped in ClosePort so g_idle payloads queued by a prior reader are
  // discarded after reopen — listening alone is not enough once Dart
  // re-subscribes or keeps the EventChannel alive across open cycles.
  std::atomic<uint64_t> open_generation{0};
  pthread_t read_thread{};
  bool read_thread_started = false;
  // g_idle_add payloads hold a raw `this`. Track source IDs so ClosePort /
  // destroy can g_source_remove them before the channel is freed.
  std::mutex idle_mutex;
  std::vector<guint> pending_idle_sources;
};

namespace {

void UntrackIdleSource(SppSerialChannel* channel, guint source_id) {
  if (channel == nullptr || source_id == 0) return;
  std::lock_guard<std::mutex> lock(channel->idle_mutex);
  auto& sources = channel->pending_idle_sources;
  for (auto it = sources.begin(); it != sources.end(); ++it) {
    if (*it == source_id) {
      sources.erase(it);
      return;
    }
  }
}

guint CurrentIdleSourceId() {
  GSource* current = g_main_current_source();
  return current != nullptr ? g_source_get_id(current) : 0;
}

void DrainIdleSources(SppSerialChannel* channel) {
  std::vector<guint> sources;
  {
    std::lock_guard<std::mutex> lock(channel->idle_mutex);
    sources.swap(channel->pending_idle_sources);
  }
  for (guint source_id : sources) {
    g_source_remove(source_id);
  }
}

gboolean SendBytesIdle(gpointer data) {
  auto* payload = static_cast<IdleBytes*>(data);
  // Resolve the source id from the running GSource — never from the payload
  // after g_idle_add_full returns. Attach can dispatch before the queuing
  // thread stores an id, and DestroyIdleBytes may free the payload before a
  // post-attach payload->source_id read.
  UntrackIdleSource(payload->channel, CurrentIdleSourceId());
  if (payload->channel != nullptr &&
      payload->generation == payload->channel->open_generation.load() &&
      payload->channel->listening.load() &&
      payload->channel->event_channel != nullptr) {
    g_autoptr(FlValue) value = fl_value_new_uint8_list(
        payload->bytes.data(), payload->bytes.size());
    g_autoptr(GError) error = nullptr;
    fl_event_channel_send(payload->channel->event_channel, value, nullptr,
                          &error);
  }
  return G_SOURCE_REMOVE;
}

gboolean SendErrorIdle(gpointer data) {
  auto* payload = static_cast<IdleError*>(data);
  UntrackIdleSource(payload->channel, CurrentIdleSourceId());
  if (payload->channel != nullptr &&
      payload->generation == payload->channel->open_generation.load() &&
      payload->channel->listening.load() &&
      payload->channel->event_channel != nullptr) {
    g_autoptr(FlValue) details = fl_value_new_int(payload->err);
    g_autoptr(GError) error = nullptr;
    fl_event_channel_send_error(payload->channel->event_channel, "read_failed",
                                "read failed", details, nullptr, &error);
  }
  return G_SOURCE_REMOVE;
}

void DestroyIdleBytes(gpointer data) {
  delete static_cast<IdleBytes*>(data);
}

void DestroyIdleError(gpointer data) {
  delete static_cast<IdleError*>(data);
}

void QueueBytes(SppSerialChannel* self, uint64_t generation,
                std::vector<uint8_t> bytes) {
  auto* payload = new IdleBytes{self, generation, std::move(bytes)};
  // Hold idle_mutex across attach + track so SendBytesIdle's Untrack cannot
  // finish (and DestroyIdleBytes cannot free `payload`) until the source id
  // is recorded. After g_idle_add_full returns, never touch `payload` again.
  std::lock_guard<std::mutex> lock(self->idle_mutex);
  const guint source_id = g_idle_add_full(
      G_PRIORITY_DEFAULT_IDLE, SendBytesIdle, payload, DestroyIdleBytes);
  if (source_id != 0) {
    self->pending_idle_sources.push_back(source_id);
  }
}

void QueueError(SppSerialChannel* self, uint64_t generation, int err) {
  auto* payload = new IdleError{self, generation, err};
  std::lock_guard<std::mutex> lock(self->idle_mutex);
  const guint source_id = g_idle_add_full(
      G_PRIORITY_DEFAULT_IDLE, SendErrorIdle, payload, DestroyIdleError);
  if (source_id != 0) {
    self->pending_idle_sources.push_back(source_id);
  }
}

void* ReadLoop(void* arg) {
  auto* self = static_cast<SppSerialChannel*>(arg);
  const uint64_t generation = self->open_generation.load();
  std::vector<uint8_t> buffer(512);
  while (self->reading.load()) {
    int fd = -1;
    {
      std::lock_guard<std::mutex> lock(self->mutex);
      fd = self->fd;
    }
    if (fd < 0) break;

    const ssize_t n = read(fd, buffer.data(), buffer.size());
    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        // termios VTIME should avoid spinning; still yield briefly.
        usleep(20000);
        continue;
      }
      // Permanent failure (device gone / hangup) — surface to Dart.
      self->reading.store(false);
      QueueError(self, generation, errno);
      break;
    }
    if (n == 0) {
      // With VMIN=0 and VTIME=2, a zero-length read is usually a termios
      // inter-byte timeout. A hung-up RFCOMM node can also return 0 after the
      // input queue drains — poll for POLLHUP/POLLERR before treating it as
      // idle so SerialTransport learns about link loss promptly.
      pollfd pfd{};
      pfd.fd = fd;
      pfd.events = POLLIN | POLLERR | POLLHUP | POLLNVAL;
      const int pr = poll(&pfd, 1, 0);
      if (pr > 0 &&
          (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
        self->reading.store(false);
        QueueError(self, generation, EIO);
        break;
      }
      continue;
    }

    QueueBytes(self, generation,
               std::vector<uint8_t>(buffer.begin(), buffer.begin() + n));
  }
  return nullptr;
}

void ClosePort(SppSerialChannel* self) {
  // Invalidate any g_idle callbacks already queued by the current reader
  // before joining it, so a fast reopen cannot deliver stale bytes/errors.
  self->open_generation.fetch_add(1);
  self->reading.store(false);
  int fd = -1;
  {
    std::lock_guard<std::mutex> lock(self->mutex);
    fd = self->fd;
    self->fd = -1;
  }
  if (fd >= 0) {
    close(fd);
  }
  if (self->read_thread_started) {
    pthread_join(self->read_thread, nullptr);
    self->read_thread_started = false;
  }
  // Reader is joined — cancel any still-queued idles before a destroy free,
  // or before a reopen starts listening again with a new generation.
  DrainIdleSources(self);
}

bool ConfigureTermios(int fd, int baud) {
  termios tio{};
  if (tcgetattr(fd, &tio) != 0) return false;
  cfmakeraw(&tio);
  const speed_t speed = BaudToFlag(baud);
  cfsetispeed(&tio, speed);
  cfsetospeed(&tio, speed);
  tio.c_cflag |= (CLOCAL | CREAD);
  tio.c_cflag &= ~PARENB;
  tio.c_cflag &= ~CSTOPB;
  tio.c_cflag &= ~CSIZE;
  tio.c_cflag |= CS8;
  // cfmakeraw does not clear CRTSCTS. Inherited RTS/CTS on an RFCOMM TTY
  // can stall write() because typical ELM327 clones never raise CTS.
  tio.c_cflag &= ~CRTSCTS;
  // ~0.2s read timeout when no bytes wait — lets ClosePort unwind.
  tio.c_cc[VMIN] = 0;
  tio.c_cc[VTIME] = 2;
  return tcsetattr(fd, TCSANOW, &tio) == 0;
}

void HandleOpen(SppSerialChannel* self, FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("invalid_args", "open requires a map",
                                     nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  FlValue* port_value = fl_value_lookup_string(args, "portName");
  if (port_value == nullptr ||
      fl_value_get_type(port_value) != FL_VALUE_TYPE_STRING) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("invalid_args", "portName required",
                                     nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  const gchar* port = fl_value_get_string(port_value);
  int baud = 38400;
  FlValue* baud_value = fl_value_lookup_string(args, "baudRate");
  if (baud_value != nullptr &&
      fl_value_get_type(baud_value) == FL_VALUE_TYPE_INT) {
    baud = static_cast<int>(fl_value_get_int(baud_value));
  }

  // Fail closed: only open paths we would list (rfcomm / bluetooth tty).
  // Reject relative paths and obvious non-BT nodes.
  if (port == nullptr || port[0] != '/' || strstr(port, "..") != nullptr) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("invalid_args", "portName must be absolute",
                                     nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  const char* base = strrchr(port, '/');
  const std::string leaf = base == nullptr ? std::string(port) : std::string(base + 1);
  if (!LooksLikeBluetoothTty(leaf)) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new(
            "open_failed", "Not a Bluetooth RFCOMM / serial node", nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  ClosePort(self);

  const int fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK);
  if (fd < 0) {
    g_autoptr(FlValue) details = fl_value_new_int(errno);
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("open_failed", g_strerror(errno),
                                     details));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  // Drop O_NONBLOCK after open so termios VTIME governs idle reads.
  const int flags = fcntl(fd, F_GETFL, 0);
  if (flags >= 0) {
    fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
  }
  if (!ConfigureTermios(fd, baud)) {
    const int err = errno;
    close(fd);
    g_autoptr(FlValue) details = fl_value_new_int(err);
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("open_failed", "tcsetattr failed",
                                     details));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  {
    std::lock_guard<std::mutex> lock(self->mutex);
    self->fd = fd;
    self->reading.store(true);
  }
  if (pthread_create(&self->read_thread, nullptr, ReadLoop, self) != 0) {
    ClosePort(self);
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("open_failed", "pthread_create failed",
                                     nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  self->read_thread_started = true;

  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  fl_method_call_respond(method_call, response, nullptr);
}

void HandleWrite(SppSerialChannel* self, FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("invalid_args", "write requires a map",
                                     nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  FlValue* bytes_value = fl_value_lookup_string(args, "bytes");
  if (bytes_value == nullptr ||
      fl_value_get_type(bytes_value) != FL_VALUE_TYPE_UINT8_LIST) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("invalid_args", "bytes must be a Uint8List",
                                     nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  const size_t length = fl_value_get_length(bytes_value);
  const uint8_t* bytes = fl_value_get_uint8_list(bytes_value);

  int fd = -1;
  {
    std::lock_guard<std::mutex> lock(self->mutex);
    fd = self->fd;
  }
  if (fd < 0) {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
        fl_method_error_response_new("not_open", "Port is not open", nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  size_t offset = 0;
  while (offset < length) {
    const ssize_t written =
        write(fd, bytes + offset, length - offset);
    if (written < 0) {
      if (errno == EINTR) continue;
      g_autoptr(FlValue) details = fl_value_new_int(errno);
      g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("write_failed", g_strerror(errno),
                                       details));
      fl_method_call_respond(method_call, response, nullptr);
      return;
    }
    if (written == 0) {
      g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("write_failed", "short write", nullptr));
      fl_method_call_respond(method_call, response, nullptr);
      return;
    }
    offset += static_cast<size_t>(written);
  }

  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  fl_method_call_respond(method_call, response, nullptr);
}

void MethodCallCb(FlMethodChannel* channel, FlMethodCall* method_call,
                  gpointer user_data) {
  (void)channel;
  auto* self = static_cast<SppSerialChannel*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "listPorts") == 0) {
    g_autoptr(FlValue) ports = EnumerateBluetoothSppPorts();
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(ports));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  if (g_strcmp0(method, "open") == 0) {
    HandleOpen(self, method_call);
    return;
  }
  if (g_strcmp0(method, "write") == 0) {
    HandleWrite(self, method_call);
    return;
  }
  if (g_strcmp0(method, "close") == 0) {
    ClosePort(self);
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(method_call, response, nullptr);
}

FlMethodErrorResponse* ListenCb(FlEventChannel* channel, FlValue* args,
                                gpointer user_data) {
  (void)channel;
  (void)args;
  auto* self = static_cast<SppSerialChannel*>(user_data);
  self->listening.store(true);
  return nullptr;
}

FlMethodErrorResponse* CancelCb(FlEventChannel* channel, FlValue* args,
                                gpointer user_data) {
  (void)channel;
  (void)args;
  auto* self = static_cast<SppSerialChannel*>(user_data);
  self->listening.store(false);
  return nullptr;
}

}  // namespace

SppSerialChannel* spp_serial_channel_new(FlBinaryMessenger* messenger) {
  auto* self = new SppSerialChannel();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->method_channel = fl_method_channel_new(
      messenger, kMethodChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->method_channel, MethodCallCb,
                                            self, nullptr);
  self->event_channel = fl_event_channel_new(
      messenger, kEventChannel, FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(self->event_channel, ListenCb, CancelCb,
                                       self, nullptr);
  return self;
}

void spp_serial_channel_destroy(SppSerialChannel* channel) {
  if (channel == nullptr) return;
  ClosePort(channel);
  g_clear_object(&channel->method_channel);
  g_clear_object(&channel->event_channel);
  delete channel;
}
