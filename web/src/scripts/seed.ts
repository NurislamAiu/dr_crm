import { prisma } from "@/lib/db";
import { hashPassword } from "@/lib/auth/password";

/**
 * Seed: организация по умолчанию + пара менеджеров с паролями.
 * organizationId="default" совпадает с DEFAULT_ORG_ID вебхука.
 * DEV-пароль обоих: "password".
 */
async function main(): Promise<void> {
  const org = await prisma.organization.upsert({
    where: { id: "default" },
    create: { id: "default", name: "Default Org" },
    update: {},
  });

  const passwordHash = hashPassword("password");
  await prisma.user.upsert({
    where: { organizationId_email: { organizationId: org.id, email: "manager@example.com" } },
    create: { organizationId: org.id, email: "manager@example.com", name: "Менеджер Алия", role: "manager", passwordHash },
    update: { passwordHash },
  });
  await prisma.user.upsert({
    where: { organizationId_email: { organizationId: org.id, email: "admin@example.com" } },
    create: { organizationId: org.id, email: "admin@example.com", name: "Админ", role: "admin", passwordHash },
    update: { passwordHash },
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
