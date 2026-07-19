import { NextResponse } from "next/server";
import { z } from "zod";
import { getAuthContext, unauthorized, forbidden, isAdmin } from "@/lib/auth/context";
import { syncUsers, syncContacts } from "@/lib/sync/sync";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BodySchema = z.object({ target: z.enum(["users", "contacts", "both"]) });

/** POST /api/admin/wazzup/sync — синхронизация менеджеров/контактов (§20, §21). */
export async function POST(req: Request): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!isAdmin(ctx)) return forbidden();

  const parsed = BodySchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Некорректные данные" }, { status: 400 });

  const result: Record<string, unknown> = {};
  if (parsed.data.target === "users" || parsed.data.target === "both") {
    result.users = await syncUsers(ctx.organizationId);
  }
  if (parsed.data.target === "contacts" || parsed.data.target === "both") {
    result.contacts = await syncContacts(ctx.organizationId);
  }
  return NextResponse.json(result);
}
