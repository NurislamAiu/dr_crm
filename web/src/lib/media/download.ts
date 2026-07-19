import { createHash } from "node:crypto";
import { prisma } from "@/lib/db";
import { logger } from "@/lib/logger";
import { putObject } from "@/lib/storage/s3";

/**
 * Скачивание входящего медиа из Wazzup contentUri в наш S3 (ТЗ §10).
 * Не блокирует обработку webhook (запускается отдельной джобой). При ошибке
 * сохраняет исходный contentUri и status=failed.
 */

const MAX_BYTES = 50 * 1024 * 1024; // §26/Wazzup: TOO_BIG_CONTENT > 50MB

const ALLOWED_PREFIXES = ["image/", "audio/", "video/"];
const ALLOWED_EXACT = new Set([
  "application/pdf",
  "application/zip",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "text/plain",
  "text/vcard",
  "application/octet-stream",
]);

function isAllowedMime(mime: string): boolean {
  return ALLOWED_PREFIXES.some((p) => mime.startsWith(p)) || ALLOWED_EXACT.has(mime);
}

function extForMime(mime: string): string {
  const map: Record<string, string> = {
    "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif",
    "audio/ogg": "ogg", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/wav": "wav",
    "video/mp4": "mp4", "video/quicktime": "mov", "application/pdf": "pdf",
    "text/plain": "txt", "text/vcard": "vcf",
  };
  return map[mime] ?? "bin";
}

export type DownloadResult = "stored" | "failed";

export async function downloadAndStoreAttachment(attachmentId: string): Promise<DownloadResult> {
  const att = await prisma.messageAttachment.findUnique({
    where: { id: attachmentId },
    select: { id: true, originalContentUri: true, status: true, message: { select: { organizationId: true } } },
  });
  if (!att || !att.originalContentUri) return "failed";
  if (att.status === "stored") return "stored";

  await prisma.messageAttachment.update({ where: { id: att.id }, data: { status: "downloading" } });

  try {
    const res = await fetch(att.originalContentUri, { redirect: "follow" });
    if (!res.ok) throw new Error(`HTTP ${res.status} при скачивании`);

    const declaredLen = Number(res.headers.get("content-length") ?? "0");
    if (declaredLen > MAX_BYTES) throw new Error("Файл превышает лимит 50MB");

    const buf = new Uint8Array(await res.arrayBuffer());
    if (buf.byteLength > MAX_BYTES) throw new Error("Файл превышает лимит 50MB");

    const mime = (res.headers.get("content-type") ?? "application/octet-stream").split(";")[0]!.trim();
    if (!isAllowedMime(mime)) throw new Error(`Недопустимый тип: ${mime}`);

    const sha256 = createHash("sha256").update(buf).digest("hex");
    const orgId = att.message.organizationId;
    const key = `media/${orgId}/${att.id}.${extForMime(mime)}`;
    await putObject(key, buf, mime);

    await prisma.messageAttachment.update({
      where: { id: att.id },
      data: { status: "stored", storageKey: key, mimeType: mime, sizeBytes: buf.byteLength, sha256, error: null },
    });
    logger.info("media: сохранено в S3", { attachmentId: att.id, mime, sizeBytes: buf.byteLength });
    return "stored";
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await prisma.messageAttachment.update({
      where: { id: att.id },
      data: { status: "failed", error: message },
    });
    logger.error("media: ошибка скачивания", { attachmentId: att.id, error: message });
    return "failed"; // исходный contentUri уже сохранён, не теряем (§10 п.8)
  }
}
