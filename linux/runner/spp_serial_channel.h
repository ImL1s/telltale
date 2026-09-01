#ifndef RUNNER_SPP_SERIAL_CHANNEL_H_
#define RUNNER_SPP_SERIAL_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

// Registers Linux Bluetooth RFCOMM / serial enumeration + open/read/write/close
// on the same Dart channel names as Windows (`com.cbstudio.telltale/spp_serial`).
// Enumerates `/dev/rfcomm*` and Bluetooth-backed tty nodes; opens at 38400 8N1.
typedef struct _SppSerialChannel SppSerialChannel;

SppSerialChannel* spp_serial_channel_new(FlBinaryMessenger* messenger);
void spp_serial_channel_destroy(SppSerialChannel* channel);

G_END_DECLS

#endif  // RUNNER_SPP_SERIAL_CHANNEL_H_
