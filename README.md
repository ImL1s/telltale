**English** | [繁體中文](README.zh-TW.md)

# Telltale

Real-time vehicle telemetry and fault diagnosis over an ELM327 OBD2 adapter.
Flutter; Android / iOS / macOS.

The source is here and you can build it and use it yourself. The paid build on
Google Play is for people who would rather not build it, and for people willing
to fund further work — it is the same app, with nothing held back.

---

## The principle this app is organized around

> **A plausible wrong number is worse than no number.**

What a diagnostic app prints gets acted on by somebody holding a wrench. A
coolant gauge reading −40 °C gets read as a dead sensor; the sentence "no fault
codes" sends a car that has a fault back out onto the road. Every rule here
exists to make uncertainty look like uncertainty instead of like an answer.

Concretely:

- **Responses are parsed against a whitelist.** Only lines that are entirely hex
  byte pairs are accepted. Stripping the non-hex characters and concatenating
  what is left turns `DATA ERROR` into the two bytes `DA AE` and reads them as a
  sensor value — a wrong number that looks perfectly reasonable.
- **Replies from multiple ECUs are never merged.** When two controllers give two
  answers to the same question, neither answer is used. Picking one is picking at
  random.
- **Silence is not an answer.** "The controllers that answered have no fault
  codes" and "this car has no fault codes" are different sentences. The screen
  always shows the first one.
- **The freeze frame's cause code is a gate.** A controller with no stored freeze
  frame does not refuse the request — it answers every PID with zeros, which
  decodes to 0 rpm and −40 °C. So the cause code is read first, and if it is not
  there, nothing is shown.
- **Derived values say where they came from.** Horsepower, torque and fuel
  consumption are computed; the screen states whether the input was a measured
  MAF or a Speed-Density estimate, and if one input is missing the whole readout
  goes unavailable rather than substituting zero.

`SPEC_DEVIATIONS.md` records, item by item, what was checked against SAE J1979
for everything that affects hardware behavior. (That document and
`FIELD_GUIDE.md` are 繁體中文 only.)

## Tests

Twelve of the tests are third-party oracles: they talk to ELM327
implementations nobody here wrote, and they self-skip unless a simulator is
listening on port 35000. So a plain `flutter test` ends in `~12`, and seeing
`~0` means you started one. The total is deliberately not quoted here — this
project has corrected a hard-coded test count in its own documentation four
times, and the fifth correction is not more likely to stick than the fourth.
Run the suite; it prints the number.

One rule governs all of them:

> **A test that does not go red under its own mutation proves nothing.**

Every fix starts with a test that fails, and once the fix is in, the fix is taken
back out to confirm the test really does go red. This is not ceremony — three
times in this project a rule was extracted into a well-tested pure function while
the call site kept its old inline copy. The suite was green and the product was
broken.

Then there is a harder layer: the **third-party oracle**.
`test/freeze_frame_oracle_test.dart` runs against an ELM327 implementation this
project did not write, because every other test here is ultimately my parser
checked against my simulator — the same reading of the standard on both sides of
the wire, so a misreading agrees with itself. It found two real defects within an
hour of being switched on.

```bash
flutter analyze
flutter test
```

## Building

Flutter 3.47.0 / Dart 3.13.0.

```bash
flutter pub get
```

Three paths from here, depending on what you want the APK for.

**Just trying it out:**

```bash
flutter build apk --debug
```

**A build to keep and use yourself:**

```bash
flutter build apk --release -PallowUnsignedRelease=true
```

That artifact is signed with the debug key. It installs and it runs, but it
belongs to a different signing lineage than the Play build, so it can never be an
update for a Telltale installed from Play — switching means uninstalling first.

**A properly signed build:**

```bash
cp android/key.properties.example android/key.properties
# generate a keystore with the keytool command inside that file, then fill in
# the four values
flutter build apk --release
```

Run `flutter build apk --release` without `android/key.properties` and Gradle
refuses and stops (`android/app/build.gradle.kts`); the refusal message itself
prints the `-P` escape hatch above. That is deliberate: a debug-signed release
artifact is indistinguishable from a real one right up until the moment you try
to update an installed copy with it and the signatures do not match. **Building
something debug-signed has to be a choice somebody made, not a default they did
not notice** — the same rule this app applies to numbers.

The app ships with a **demo simulator** — every screen works with no adapter and
no car, fault codes, freeze frames and emissions readiness included. It is
deliberately as strict as real hardware (it emits `SEARCHING...`, multi-frame
responses with length lines, the all-zero trap after a clear), because back when
it was more forgiving than a real ELM327, three CRITICAL defects survived
underneath a green test suite — two in the parser, and one an AT initialisation
command that a strict simulator would not have caught either. `REVIEW_LOG.md`
names all three.

## Before you get in the car

`FIELD_GUIDE.md` is written for the person sitting in the driver's seat: how to
choose an adapter, what to do when it will not connect, what that one line of
fault-code verdict actually proves, and what to look at before clearing anything.
It is 繁體中文 only for now.

## License

GPL-3.0. Use it, modify it, redistribute it; derivative works must be open source
under the same terms.

## Disclaimer

This app has no affiliation with Ian Hawkins' Torque or Torque Pro and is neither
an official nor a derivative version of either. The OBD2 implementation follows
public standards including SAE J1979 and the ELM327 datasheet.
