import { headers } from "next/headers";

/**
 * DEV-контекст авторизации. Этап 7 заменит на проверку JWT (Auth.js/Bearer)
 * и RBAC. Пока читаем org/user из заголовков (или дефолт), чтобы API
 * можно было отдать Flutter-приложению уже сейчас.
 *
 * ВАЖНО: organizationId и права НЕ должны браться из тела запроса от клиента.
 */
export interface AuthContext {
  organizationId: string;
  userId: string | null;
}

export async function getAuthContext(): Promise<AuthContext> {
  const h = await headers();
  return {
    organizationId: h.get("x-org-id") ?? process.env.DEFAULT_ORG_ID ?? "default",
    userId: h.get("x-user-id"),
  };
}
