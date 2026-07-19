import { NextResponse } from "next/server";
import { getEnv } from "@/lib/env";
import { getAuthContext, unauthorized, forbidden, isAdmin } from "@/lib/auth/context";
import { getWazzupClient } from "@/lib/wazzup/factory";
import { WazzupApiError } from "@/lib/wazzup/errors";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** GET — «Проверить webhook»: текущие настройки в Wazzup (§7). */
export async function GET(req: Request): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!isAdmin(ctx)) return forbidden();

  try {
    const settings = await getWazzupClient().getWebhookSettings();
    return NextResponse.json({ settings });
  } catch (err) {
    const message = err instanceof WazzupApiError ? err.userFacingMessage() : "Не удалось получить настройки";
    return NextResponse.json({ error: message }, { status: 502 });
  }
}

/**
 * POST — «Настроить webhook»: PATCH /v3/webhooks (§7).
 * webhooksUri = APP_URL/api/webhooks/wazzup?secret=... contactsAndDealsCreation
 * и templateStatus = false (клиентов создаём сами; QR-канал не использует WABA).
 */
export async function POST(req: Request): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!isAdmin(ctx)) return forbidden();

  const env = getEnv();
  if (!env.APP_URL) return NextResponse.json({ error: "APP_URL не задан" }, { status: 400 });

  const webhooksUri = `${env.APP_URL}/api/webhooks/wazzup?secret=${encodeURIComponent(env.WAZZUP_WEBHOOK_SECRET)}`;
  try {
    await getWazzupClient().configureWebhooks({
      webhooksUri,
      subscriptions: {
        messagesAndStatuses: true,
        contactsAndDealsCreation: false,
        channelsUpdates: true,
        templateStatus: false,
      },
    });
    return NextResponse.json({ ok: true, webhooksUri: webhooksUri.replace(/secret=[^&]+/, "secret=***") });
  } catch (err) {
    const message = err instanceof WazzupApiError ? err.userFacingMessage() : "Не удалось настроить webhook";
    return NextResponse.json({ error: message }, { status: 502 });
  }
}
