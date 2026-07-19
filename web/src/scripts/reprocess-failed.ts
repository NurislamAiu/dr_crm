import { prisma } from "@/lib/db";
import { enqueueWebhookEvent } from "@/lib/queue/webhook-queue";

/** Переобработать упавшие webhook-события (после исправления схемы/нормализатора). */
async function main(): Promise<void> {
  const evs = await prisma.wazzupWebhookEvent.findMany({
    where: { status: "failed" },
    select: { id: true },
  });
  for (const e of evs) {
    await prisma.wazzupWebhookEvent.update({
      where: { id: e.id },
      data: { status: "received", error: null },
    });
    await enqueueWebhookEvent(e.id);
  }
  console.log(`re-enqueued ${evs.length} failed webhook event(s)`);
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
