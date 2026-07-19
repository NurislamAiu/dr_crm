import { prisma } from "@/lib/db";
import { getEnv } from "@/lib/env";
import { getWazzupClient } from "@/lib/wazzup/factory";
import { logger } from "@/lib/logger";
import type { WazzupUser, WazzupContact } from "@/lib/wazzup/schemas";

/**
 * Синхронизация менеджеров и контактов в Wazzup (ТЗ §20, §21).
 * Батчи ≤100 сущностей за запрос; между батчами пауза (лимит 500 req/5s, §26).
 * Source of truth — наша CRM.
 */

const BATCH = 100;

function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export interface SyncStats {
  total: number;
  batches: number;
  ok: boolean;
  error?: string;
}

/**
 * POST /v3/users. id — стабильный UUID пользователя CRM (не email, §20).
 */
export async function syncUsers(organizationId: string): Promise<SyncStats> {
  const users = await prisma.user.findMany({
    where: { organizationId, isActive: true },
    select: { id: true, name: true },
  });
  const payload: WazzupUser[] = users.map((u) => ({ id: u.id, name: u.name }));
  const client = getWazzupClient();

  const job = await prisma.wazzupSyncJob.create({
    data: { organizationId, kind: "users", status: "running", startedAt: new Date() },
    select: { id: true },
  });

  try {
    const batches = chunk(payload, BATCH);
    for (const [i, b] of batches.entries()) {
      await client.syncUsers(b);
      if (i < batches.length - 1) await sleep(200);
    }
    await prisma.user.updateMany({
      where: { organizationId, isActive: true },
      data: { wazzupSyncedAt: new Date() },
    });
    await prisma.wazzupSyncJob.update({
      where: { id: job.id },
      data: { status: "done", finishedAt: new Date(), stats: { total: payload.length, batches: batches.length } },
    });
    logger.info("sync: users готово", { total: payload.length, batches: batches.length });
    return { total: payload.length, batches: batches.length, ok: true };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    await prisma.wazzupSyncJob.update({ where: { id: job.id }, data: { status: "failed", finishedAt: new Date(), error } });
    logger.error("sync: users ошибка", { error });
    return { total: payload.length, batches: 0, ok: false, error };
  }
}

/**
 * POST /v3/contacts. uri ведёт на карточку клиента в нашей CRM (§21).
 */
export async function syncContacts(organizationId: string): Promise<SyncStats> {
  const env = getEnv();
  const fallbackUser = await prisma.user.findFirst({
    where: { organizationId, isActive: true, role: { in: ["admin", "manager"] } },
    orderBy: { createdAt: "asc" },
    select: { id: true },
  });

  const contacts = await prisma.contact.findMany({
    where: { organizationId },
    select: { id: true, name: true, chatType: true, chatId: true, responsibleUserId: true },
  });

  const payload: WazzupContact[] = contacts
    .map((c) => {
      const responsibleUserId = c.responsibleUserId ?? fallbackUser?.id;
      if (!responsibleUserId) return null; // без ответственного контакт не синкаем
      const uri = env.APP_URL ? `${env.APP_URL}/contacts/${c.id}` : undefined;
      return {
        id: c.id,
        responsibleUserId,
        name: c.name,
        contactData: [{ chatType: c.chatType as "whatsapp", chatId: c.chatId }],
        ...(uri ? { uri } : {}),
      } as WazzupContact;
    })
    .filter((x): x is WazzupContact => x !== null);

  const client = getWazzupClient();
  const job = await prisma.wazzupSyncJob.create({
    data: { organizationId, kind: "contacts", status: "running", startedAt: new Date() },
    select: { id: true },
  });

  try {
    const batches = chunk(payload, BATCH);
    for (const [i, b] of batches.entries()) {
      await client.syncContacts(b);
      if (i < batches.length - 1) await sleep(200);
    }
    await prisma.wazzupSyncJob.update({
      where: { id: job.id },
      data: { status: "done", finishedAt: new Date(), stats: { total: payload.length, batches: batches.length } },
    });
    logger.info("sync: contacts готово", { total: payload.length, batches: batches.length });
    return { total: payload.length, batches: batches.length, ok: true };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    await prisma.wazzupSyncJob.update({ where: { id: job.id }, data: { status: "failed", finishedAt: new Date(), error } });
    logger.error("sync: contacts ошибка", { error });
    return { total: payload.length, batches: 0, ok: false, error };
  }
}

export { chunk as _chunkForTest };
