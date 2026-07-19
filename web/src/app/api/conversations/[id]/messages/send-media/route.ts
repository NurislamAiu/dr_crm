import { NextResponse } from "next/server";
import { getAuthContext, unauthorized, forbidden, canWrite } from "@/lib/auth/context";
import { createOutboundMedia } from "@/lib/outbound/send-message";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /api/conversations/:id/messages/send-media — отправка вложения (§14).
 * multipart/form-data: file (обязательно), caption (необязательно).
 * Файл грузится ТОЛЬКО на наш backend, затем в S3, затем в Wazzup через contentUri.
 */
export async function POST(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!canWrite(ctx)) return forbidden();
  const { organizationId, userId } = ctx;
  const { id } = await params;

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return NextResponse.json({ error: "Ожидается multipart/form-data" }, { status: 400 });
  }

  const file = form.get("file");
  if (!(file instanceof File)) {
    return NextResponse.json({ error: "Файл не передан" }, { status: 400 });
  }
  const caption = form.get("caption");

  const bytes = new Uint8Array(await file.arrayBuffer());
  const result = await createOutboundMedia({
    organizationId,
    conversationId: id,
    userId,
    fileName: file.name || "file",
    mimeType: file.type || "application/octet-stream",
    bytes,
    caption: typeof caption === "string" ? caption : undefined,
  });

  if (!result.ok) {
    const status = result.code === "not_found" ? 404 : result.code === "too_big" ? 413 : 400;
    return NextResponse.json({ error: result.error }, { status });
  }
  return NextResponse.json({ messageIds: result.messageIds, status: "queued" }, { status: 202 });
}
