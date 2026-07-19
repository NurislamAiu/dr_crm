import type { ReactNode } from "react";

export const metadata = {
  title: "CRM — WhatsApp чаты",
  description: "Собственный интерфейс чатов поверх Wazzup User API v3",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="ru">
      <body>{children}</body>
    </html>
  );
}
