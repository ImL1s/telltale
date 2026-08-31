#ifndef RUNNER_SPP_SERIAL_CHANNEL_H_
#define RUNNER_SPP_SERIAL_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>

#include <memory>

// Registers Windows Bluetooth-SPP COM enumeration + open/read/write/close.
// Lifetime is owned by FlutterWindow.
class SppSerialChannel {
 public:
  explicit SppSerialChannel(flutter::BinaryMessenger* messenger);
  ~SppSerialChannel();

  SppSerialChannel(const SppSerialChannel&) = delete;
  SppSerialChannel& operator=(const SppSerialChannel&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_SPP_SERIAL_CHANNEL_H_
