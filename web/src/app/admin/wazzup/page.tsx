"use client";

import { useState } from "react";

/**
 * Тонкая веб-админка: Настройки → Wazzup → Диагностика (§25).
 * Логин админом → JWT в состоянии страницы; кнопки диагностики/настройки webhook
 * и синхронизации. Полноценный чат — в мобильном Flutter-приложении.
 */
export default function WazzupAdminPage() {
  const [email, setEmail] = useState("admin@example.com");
  const [password, setPassword] = useState("");
  const [token, setToken] = useState<string | null>(null);
  const [out, setOut] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function call(path: string, init?: RequestInit) {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch(path, {
        ...init,
        headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...(init?.headers ?? {}) },
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error ?? `HTTP ${res.status}`);
      return data;
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      return null;
    } finally {
      setBusy(false);
    }
  }

  async function login() {
    const data = await call("/api/auth/login", { method: "POST", body: JSON.stringify({ email, password }) });
    if (data?.token) setToken(data.token as string);
  }

  const box: React.CSSProperties = { fontFamily: "system-ui", maxWidth: 820, margin: "0 auto", padding: 24 };
  const btn: React.CSSProperties = { padding: "8px 12px", marginRight: 8, marginBottom: 8, cursor: "pointer" };

  return (
    <main style={box}>
      <h1>Wazzup — Диагностика</h1>
      {!token ? (
        <div>
          <p>Вход администратора:</p>
          <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="email" style={{ padding: 8, marginRight: 8 }} />
          <input value={password} onChange={(e) => setPassword(e.target.value)} type="password" placeholder="пароль" style={{ padding: 8, marginRight: 8 }} />
          <button style={btn} onClick={login} disabled={busy}>Войти</button>
        </div>
      ) : (
        <div>
          <div style={{ marginBottom: 12 }}>
            <button style={btn} onClick={async () => setOut(await call("/api/admin/wazzup/diagnostics"))} disabled={busy}>Диагностика</button>
            <button style={btn} onClick={async () => setOut(await call("/api/admin/wazzup/webhooks"))} disabled={busy}>Проверить webhook</button>
            <button style={btn} onClick={async () => setOut(await call("/api/admin/wazzup/webhooks", { method: "POST" }))} disabled={busy}>Настроить webhook</button>
            <button style={btn} onClick={async () => setOut(await call("/api/admin/wazzup/sync", { method: "POST", body: JSON.stringify({ target: "users" }) }))} disabled={busy}>Синхр. менеджеров</button>
            <button style={btn} onClick={async () => setOut(await call("/api/admin/wazzup/sync", { method: "POST", body: JSON.stringify({ target: "contacts" }) }))} disabled={busy}>Синхр. контактов</button>
            <button style={btn} onClick={() => setToken(null)}>Выйти</button>
          </div>
        </div>
      )}
      {error && <p style={{ color: "crimson" }}>Ошибка: {error}</p>}
      {out != null && (
        <pre style={{ background: "#f4f4f5", padding: 16, borderRadius: 8, overflow: "auto", fontSize: 13 }}>
          {JSON.stringify(out, null, 2)}
        </pre>
      )}
    </main>
  );
}
