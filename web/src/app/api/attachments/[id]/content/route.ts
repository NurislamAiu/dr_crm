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
  // undici принимает Uint8Array как тело; приведение из-за строгих DOM-типов.
  return new Response(bytes as unknown as BodyInit, {
    status: 200,
    headers: {
      "content-type": att.mimeType ?? "application/octet-stream",
      "cache-control": "private, max-age=300",
      "content-length": String(bytes.byteLength),
    },
  });
}
