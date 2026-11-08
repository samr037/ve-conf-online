// MK3-USB over Web Serial — DRAFT, read-only, not used by the app yet. See web/docs/mk3-webserial.md.
export { FrameReader, checksum, encodeFrame, type Frame } from './frame'
export { DEFAULT_TIMEOUT_MS, Mk3Client, Mk3TimeoutError, Winmon, type RawSettingInfo, type WFrame } from './mk3'
export { draftConfiguration, readConfiguration, type DeviceReading, type ReadOptions } from './readConfiguration'
export { MK2_BAUD_RATE, MK3_USB_FILTER, MockTransport, WebSerialTransport, webSerialAvailable, type SerialTransport } from './transport'
