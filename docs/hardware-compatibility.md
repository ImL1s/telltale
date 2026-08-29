# Hardware compatibility / 硬體相容性

This page records combinations that were actually observed. It is not an
adapter certification, a buying guarantee, or a claim that every item under a
marketplace listing contains the same hardware.

本頁只記錄實際觀察過的組合，不是轉接器認證、購買保證，也不代表同一賣場連結下的
每一批商品都使用相同硬體。

## CARLZS LAB CL-OBDII-M25B on Toyota GT86

| Field | Observed value |
| --- | --- |
| Adapter | CARLZS LAB `CL-OBDII-M25B` |
| Radio identifier | `OBDBLE` over Bluetooth LE |
| Taiwan radio approval shown for this model | NCC `CCAH22LP5300T8` |
| Phone | Samsung `SM-S9280`, Android 16 |
| App | Telltale `1.0.4+5` |
| Vehicle | Toyota GT86; model year and ECU calibration not recorded here |
| Retained evidence | 418,028-byte recovered Telltale session dated 2026-08-27 |

The maintainer reports using this exact adapter to connect Telltale to the
GT86. A fresh inspection of the same phone on 2026-08-29 found the remembered
`OBDBLE` adapter, Bluetooth LE as the transport, and the retained session
record. The raw transcript is intentionally not published because OBD exports
can contain VIN, phone, and adapter identifiers. It was reviewed locally; only
de-identified framing shapes and synthetic sensor values are public test data.

維護者已用這支轉接器讓 Telltale 連上 GT86。2026-08-29 再檢查同一支手機時，App
仍記得 `OBDBLE`、Bluetooth LE 連線方式，以及上述復原工作階段。原始紀錄可能含
VIN、手機與轉接器識別資訊，所以不公開。

### What this establishes

- One real CL-OBDII-M25B, one Samsung phone, and one GT86 completed a Telltale
  BLE connection and left a substantial session record.
- The adapter reported CAN 11-bit/500 kbit/s. In the retained idle-only ranges,
  repeated single- and multi-PID replies completed without `NO DATA`, CAN/BUS
  errors, timeouts, or malformed frames.
- The field shapes now have a privacy-safe regression fixture covering a stray
  reset byte, chained PID-support masks, `7F 01 12`, split notifications, and a
  numbered three-segment batch.
- The product link below points to the adapter model used by the maintainer as
  checked on 2026-08-29.

### What this does not establish

- It does not certify every unit, marketplace revision, phone, GT86 model year,
  ECU, or supported OBD PID.
- The 22-minute export preserved the handshake and latest traffic but dropped
  12,953 middle entries. It therefore cannot establish continuity, sustained
  polling for the whole run, disconnect cause, or road/ignition/crank behaviour.
- The retained ranges were stationary idle data. They do not establish PID
  accuracy, DTC coverage, engine-load behaviour, or any other GT86/model year,
  ECU calibration, phone, adapter unit, or marketplace revision.
- NCC approval concerns the radio equipment; it is not proof of vehicle or OBD
  protocol compatibility.

The full software, device, commercial-simulator, and real-vehicle evidence
layers are kept in the [verification rig matrix](verification/rig-matrix.md).

### Purchase link / 購買連結

**[Shopee affiliate link / 蝦皮推廣分潤連結](https://s.shopee.tw/3LQPiOY7uv)**

This is the maintainer's affiliate link. A qualifying purchase may pay the
maintainer a commission. You are free to search for or buy the same model
elsewhere. Marketplace content and hardware revisions can change; verify the
full model `CL-OBDII-M25B` and NCC number `CCAH22LP5300T8` before buying.

這是維護者的推廣分潤連結；符合條件的購買可能讓維護者取得佣金。你也可以自行搜尋
或向其他通路購買同型號。賣場內容與硬體版本可能變更，購買前請核對完整型號
`CL-OBDII-M25B` 與 NCC 號碼 `CCAH22LP5300T8`。
