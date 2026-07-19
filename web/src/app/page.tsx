export default function HomePage() {
  return (
    <main style={{ fontFamily: "system-ui", padding: 24 }}>
      <h1>CRM — WhatsApp чаты</h1>
      <p>Backend интеграции Wazzup v3. Интерфейс менеджеров — Этап 4.</p>
      <ul>
        <li>
          <code>POST /api/webhooks/wazzup</code> — приём webhook Wazzup
        </li>
        <li>
          <code>GET /api/health</code> — health check
        </li>
      </ul>
    </main>
  );
}
