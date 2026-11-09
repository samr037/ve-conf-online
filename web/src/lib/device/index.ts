// MK2/MK3 over Web Serial, read-only beta. See web/docs/mk3-webserial.md.
export { FrameReader, checksum, encodeFrame, type Frame } from './frame'
export { ForbiddenFrameError, READ_ONLY_WINMON, ReadOnlyTransport, assertReadOnlyFrame } from './guard'
export { DEFAULT_TIMEOUT_MS, Mk3Client, Mk3TimeoutError, Winmon, type RawSettingInfo, type WFrame } from './mk3'
export { discoverDevices, draftConfiguration, readConfiguration, type DeviceReading, type ReadOptions } from './readConfiguration'
export {
  DeviceLostError, MK2_BAUD_RATE, MK3_USB_FILTER, MockTransport, WebSerialTransport, portLabel, requestPort, webSerialAvailable,
  type SerialTransport,
} from './transport'
