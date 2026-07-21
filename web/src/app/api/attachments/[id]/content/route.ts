import { NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import { getAuthContext, unauthorized } from "@/lib/auth/context";
import { getObjectBytes } from "@/lib/storage/s3";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /api/attachments/:id/content — проксирование содержимого вложения через
 * backend (§10, §24). Так приложение грузит файл с того же хоста, что и API
 * (не с внутреннего S3/MinIO), с проверкой JWT и принадлежности организации.
 * Токен передаётся заголовком Authorization (Image.network поддерживает headers).
 */
export async function GET(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  const { id } = await params;

  const att = await prisma.messageAttachment.findFirst({
    where: { id, message: { organizationId: ctx.organizationId } },
    select: { storageKey: true, mimeType: true, status: true },
  });
  if (!att) return NextResponse.json({ error: "not found" }, { status: 404 });
  if (att.status !== "stored" || !att.storageKey) {
    return NextResponse.json({ status: att.status, error: "Файл ещё не готов" }, { status: 409 });
  }

  const bytes = await getObjectBytes(att.storageKey);
  const total = bytes.byteLength;
  const contentType = att.mimeType ?? "application/octet-stream";
  // Accept-Ranges обязателен: iOS-плеер (AVPlayer/just_audio) требует Range для
  // прогрессивного воспроизведения аудио/видео — иначе setAudioSource падает.
  const baseHeaders: Record<string, string> = {
    "content-type": contentType,
    "cache-control": "private, max-age=300",
    "accept-ranges": "bytes",
  };

  const range = req.headers.get("range");
  const m = range ? /^bytes=(\d*)-(\d*)$/.exec(range.trim()) : null;
  if (m) {
    const g1 = m[1] ?? "";
    const g2 = m[2] ?? "";
    let start: number;
    let end: number;
    if (g1 === "" && g2 !== "") {
      // суффиксный диапазон: последние N байт
      const n = parseInt(g2, 10);
      start = Math.max(0, total - n);
      end = total - 1;
    } else {
      start = g1 ? parseInt(g1, 10) : 0;
      end = g2 ? parseInt(g2, 10) : total - 1;
    }
    if (Number.isNaN(start)) start = 0;
    if (Number.isNaN(end) || end >= total) end = total - 1;
    if (start > end || start >= total) {
      return new Response(null, {
        status: 416,
        headers: { ...baseHeaders, "content-range": `bytes */${total}` },
      });
    }
    const chunk = bytes.subarray(start, end + 1);
    // undici принимает Uint8Array как тело; приведение из-за строгих DOM-типов.
    return new Response(chunk as unknown as BodyInit, {
      status: 206,
      headers: {
        ...baseHeaders,
        "content-range": `bytes ${start}-${end}/${total}`,
        "content-length": String(chunk.byteLength),
      },
    });
  }

  return new Response(bytes as unknown as BodyInit, {
    status: 200,
    headers: { ...baseHeaders, "content-length": String(total) },
  });
}
