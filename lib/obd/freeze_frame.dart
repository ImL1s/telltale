/// The snapshot an ECU stored at the instant it confirmed a fault.
///
/// Service $02 (SAE J1979). When a controller sets an emissions DTC it freezes
/// a copy of the sensor values it was reading at that moment, and this is the
/// only way to see the car as it was when the fault happened rather than as it
/// is now, idling on a driveway with the problem not occurring. It is the
/// difference between "P0171 系統過稀" and "P0171 系統過稀，在 2800 rpm、
/// 88 °C、負荷 74% 的時候" — the second one is a diagnosis and the first is a
/// starting point.
///
/// The wire format differs from Mode 01 by one byte in each direction: the
/// request is `02 <PID> <frame>` and the reply is `42 <PID> <frame> <data>`.
/// The frame number is not decoration — a conforming ECU will not answer a
/// two-byte `02 <PID>` at all, and a permissive clone answers anyway with the
/// data shifted one byte, which produces a reading that looks plausible and is
/// wrong. `PollableServices` already encodes this for custom PIDs; this is the
/// same rule for the built-in path.
library;

import 'dtc/dtc.dart';
import 'pid/pid.dart';

/// One decoded value out of a freeze frame.
class FreezeReading {
  const FreezeReading({
    required this.pid,
    required this.value,
    required this.raw,
  });

  final Pid pid;

  /// The formula's result, in [Pid.units].
  final double value;

  /// The data bytes it came from, kept so the transcript can show the wire
  /// alongside the number. A freeze frame is read once and cannot be re-read
  /// after a clear, so anything discarded here is gone.
  final List<int> raw;
}

/// One controller's freeze frame.
///
/// [cause] is never null and is never the `0x0000` padding: a frame is only
/// constructed once the controller has named the code that stored it. That is
/// the gate the whole feature hangs on, and the reason is the failure it
/// prevents rather than tidiness — see [FreezeFrame.noFrameStored].
class FreezeFrame {
  const FreezeFrame({
    required this.source,
    required this.frameNumber,
    required this.cause,
    required this.readings,
    required this.undecodable,
    required this.unread,
    this.contentsUnknown = false,
  });

  /// The controller that answered, e.g. `7E8`.
  final String source;

  /// Which frame. Zero on nearly every vehicle; carried because the request
  /// cannot be formed without it.
  final int frameNumber;

  /// The DTC whose storage caused this snapshot to be taken.
  final Dtc cause;

  final List<FreezeReading> readings;

  /// How many PIDs the controller reported as present in the frame that this
  /// app has no definition for.
  ///
  /// Counted and shown rather than dropped, for the same reason the readiness
  /// card lists unsupported monitors: a list silently shortened to what the app
  /// understands looks like the whole frame, and somebody comparing it against
  /// a scan-tool printout would find values missing with nothing saying why.
  final int undecodable;

  /// How many PIDs the controller listed that no usable value came back for.
  ///
  /// A read that timed out, a controller that did not answer its own claim, or
  /// two replies that disagreed — all of them "we could not establish this",
  /// which is a different sentence from "this app has no formula for it" and
  /// calls for a different action: rescan, rather than accept the limit.
  ///
  /// It exists because the freeze read runs last, under the scan's shared
  /// deadline. On a slow adapter the deterministic shape is that the early PIDs
  /// land and the later ones expire, and without this the table simply gets
  /// shorter — a partial frame presented as a whole one, which is the failure
  /// [undecodable] was already added to prevent, arriving through the other
  /// door.
  ///
  /// Derived at the end from what was claimed against what came back, rather
  /// than accumulated as it goes. A counter incremented at four call sites is
  /// a rule in four places, and this file's neighbours are a long record of
  /// what happens to those.
  final int unread;

  /// The controller has a frame and would not say what is in it.
  ///
  /// Its support mask did not come back — a timeout, or a module that answers
  /// the causing code and nothing else. Without this, that controller is
  /// indistinguishable from one whose frame held nothing this app can read, and
  /// the screen said 「有凍結幀，但沒有本 App 能解讀的項目」 — a claim about the
  /// contents, made from a failure to fetch them. The two need different
  /// sentences because they call for different actions: one is "your app is
  /// limited", the other is "try again".
  final bool contentsUnknown;

  /// Why a controller with a stored code can still have nothing to show.
  ///
  /// `42 02 <frame> 00 00` is a controller saying, in the reply that is
  /// supposed to name the causing code, that there is no code — which means
  /// there is no frame. Every other Mode 02 PID will then answer with zeroes,
  /// and those zeroes decode into perfectly well-formed readings: 0 rpm,
  /// −40 °C coolant, 0% load. Rendered under 故障發生當下的車況 that is a
  /// confident, precise, entirely fictional account of a moment that never
  /// happened, and somebody would diagnose against it.
  ///
  /// So the causing code is read *first* and nothing else is asked for until it
  /// decodes to a real DTC. A car with no frame costs one round trip and can
  /// never produce a number.
  static const String noFrameStored =
      '這個控制器沒有儲存凍結幀 —— 故障碼可能是清除後重新出現的，'
      '或是由不記錄凍結幀的模組所報告。';
}

/// What one Mode 02 read produced, and whether it produced all of it.
///
/// The list alone could not say. Throwing covers an exchange that *failed* —
/// a timeout, a refused bus — but a reply the adapter marked successful can
/// still be damaged: a causing-code frame cut short by a lost CAN frame, or one
/// that arrived with no header to attribute it to. Both were dropped silently,
/// and if that was the only controller the result was an empty list, which the
/// screen renders as 沒有儲存凍結幀 and the field guide tells the reader is not
/// bad news — over a button that destroys the frame.
///
/// [incomplete] also covers the partial case, which is the quieter one: two
/// controllers with codes, one answering cleanly and one damaged. The good
/// frame renders, nothing is obviously missing, and the second controller is
/// read as having stored nothing.
class FreezeFrameRead {
  const FreezeFrameRead({required this.frames, required this.incomplete});

  const FreezeFrameRead.complete(this.frames) : incomplete = false;

  final List<FreezeFrame> frames;

  /// Something in this read did not arrive intact. Whatever is in [frames] is
  /// still trustworthy — damage is dropped, never repaired — but the set is
  /// not known to be all of it.
  final bool incomplete;
}
