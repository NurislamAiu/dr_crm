import { prisma } from "@/lib/db";

/**
 * Seed: организация по умолчанию + пара менеджеров.
 * organizationId="default" совпадает с DEFAULT_ORG_ID вебхука.
 */
async function main(): Promise<void> {
  const org = await prisma.organization.upsert({
    where: { id: "default" },
    create: { id: "default", name: "Default Org" },
    update: {},
  });

  await prisma.user.upsert({
    where: { organizationId_email: { organizationId: org.id, email: "manager@example.com" } },
    create: { organizationId: org.id, email: "manager@example.com", name: "Менеджер Алия", role: "manager" },
    update: {},
  });
  await prisma.user.upsert({
    where: { organizationId_email: { organizationId: org.id, email: "admin@example.com" } },
    create: { organizationId: org.id, email: "admin@example.com", name: "Админ", role: "admin" },
    update: {},
  });

  const count = await prisma.user.count({ where: { organizationId: org.id } });
  console.log(`Seed готов: org=${org.id}, пользователей=${count}`);
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
