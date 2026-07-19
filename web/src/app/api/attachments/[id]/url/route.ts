import { NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import { getAuthContext, unauthorized } from "@/lib/auth/context";
import { signedGetUrl } from "@/lib/storage/s3";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /api/attachments/:id/url — короткоживущий signed URL вложения (§10, §24).
 * Не отдаём URL Wazzup напрямую; отдаём ссылку на наш S3. Проверяем, что
 * вложение принадлежит организации запрашивающего.
 */
export async function GET(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  const { organizationId } = ctx;
  const { id } = await params;

  const att = await prisma.messageAttachment.findFirst({
    where: { id, message: { organizationId } },
    select: { id: true, kind: true, mimeType: true, sizeBytes: true, status: true, storageKey: true },
  });
  if (!att) return NextResponse.json({ error: "not found" }, { status: 404 });

  if (att.status !== "stored" || !att.storageKey) {
    return NextResponse.json(
      { status: att.status, error: "Файл ещё не готов" },
      { status: 409 },
    );
  }

  const url = await signedGetUrl(att.storageKey, 300);
  return NextResponse.json({
    url,
    kind: att.kind,
    mimeType: att.mimeType,
    sizeBytes: att.sizeBytes,
    expiresInSeconds: 300,
  });
}
