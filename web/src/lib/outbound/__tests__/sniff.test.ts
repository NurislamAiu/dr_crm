import { test, expect } from "vitest";
import { _sniffMimeForTest as sniff } from "../send-message";

const bytes = (...arr: number[]) => new Uint8Array(arr);
const OCTET = "application/octet-stream";

test("sniff: JPEG по сигнатуре → image/jpeg (фото не станет документом)", () => {
  expect(sniff(bytes(0xff, 0xd8, 0xff, 0xe0, 0, 0), OCTET)).toBe("image/jpeg");
});

test("sniff: PNG → image/png", () => {
  expect(sniff(bytes(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a), OCTET)).toBe("image/png");
});

test("sniff: HEIC (ftyp heic) → image/heic", () => {
  const b = bytes(0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63); // ....ftypheic
  expect(sniff(b, OCTET)).toBe("image/heic");
});

test("sniff: MP4 (ftyp mp42) → video/mp4", () => {
  const b = bytes(0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6d, 0x70, 0x34, 0x32);
  expect(sniff(b, OCTET)).toBe("video/mp4");
});

test("sniff: PDF → application/pdf", () => {
  expect(sniff(bytes(0x25, 0x50, 0x44, 0x46, 0x2d), OCTET)).toBe("application/pdf");
});

test("sniff: конкретный MIME от клиента не трогаем", () => {
  expect(sniff(bytes(0xff, 0xd8, 0xff), "image/png")).toBe("image/png");
});

test("sniff: неизвестное содержимое остаётся octet-stream", () => {
  expect(sniff(bytes(0x01, 0x02, 0x03, 0x04), OCTET)).toBe(OCTET);
});
