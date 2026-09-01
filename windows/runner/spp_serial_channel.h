#ifndef RUNNER_SPP_SERIAL_CHANNEL_H_
#define RUNNER_SPP_SERIAL_CHANNEL_H_

#include <flutter/flutter_engine.h>

#include <memory>

// Registers Windows Bluetooth-SPP COM enumeration + open/read/write/close.
// Lifetime is owned by FlutterWindow.
class SppSerialChannel {
 public:
  // |engine| must outlive this channel; EventSink traffic is posted onto its
  // platform thread via PostPlatformThreadTask.
  explicit SppSerialChannel(flutter::FlutterEngine* engine);
  ~SppSerialChannel();

  SppSerialChannel(const SppSerialChannel&) = delete;
  SppSerialChannel& operator=(const SppSerialChannel&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_SPP_SERIAL_CHANNEL_H_
