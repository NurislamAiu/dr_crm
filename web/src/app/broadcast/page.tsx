"use client";

import { useRef, useState } from "react";

/**
 * Рассылка сервисных напоминаний пациентам (которые уже писали клинике).
 * Шаблон с {name}, список «Имя;+7…», отправка через /api/broadcast/send
 * с паузой 20 c между контактами и живым прогрессом.
 */

const DEFAULT_TEXT = `Здравствуйте, {name}!
DR.TOITAYEV: напоминаем, что 22 июля у Вас запись к врачу.
Для подтверждения, переноса или отмены записи напишите нам в WhatsApp на номер +7 777 175 44 45`;

const DELAY_MS = 20000;

type Row = { name: string; phone: string; status: "pending" | "sending" | "sent" | "failed"; error?: string };

export default function BroadcastPage() {
  const [email, setEmail] = useState("admin@example.com");
  const [password, setPassword] = useState("");
  const [token, setToken] = useState<string | null>(null);
  const [loginErr, setLoginErr] = useState<string | null>(null);

  const [text, setText] = useState(DEFAULT_TEXT);
  const [contactsRaw, setContactsRaw] = useState("");
  const [rows, setRows] = useState<Row[]>([]);
  const [running, setRunning] = useState(false);
  const [countdown, setCountdown] = useState(0);
  const stopRef = useRef(false);

  async function login() {
    setLoginErr(null);
    try {
      const res = await fetch("/api/auth/login", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email, password }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error ?? `HTTP ${res.status}`);
      setToken(data.token as string);
    } catch (e) {
      setLoginErr(e instanceof Error ? e.message : String(e));
    }
  }

  function parseContacts(): Row[] {
    return contactsRaw
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean)
      .map((line) => {
        const sep = line.includes(";") ? ";" : line.includes(",") ? "," : "\t";
        const [name, phone] = line.split(sep);
        return { name: (name ?? "").trim(), phone: (phone ?? "").trim(), status: "pending" as const };
      })
      .filter((r) => r.phone.length > 0);
  }

  function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => {
      let left = Math.ceil(ms / 1000);
      setCountdown(left);
      const t = setInterval(() => {
        left -= 1;
        setCountdown(left);
        if (left <= 0 || stopRef.current) {
          clearInterval(t);
          resolve();
        }
      }, 1000);
    });
  }

  async function start() {
    const parsed = parseContacts();
    if (parsed.length === 0) return;
    setRows(parsed);
    setRunning(true);
    stopRef.current = false;

    for (let i = 0; i < parsed.length; i++) {
      if (stopRef.current) break;
      const contact = parsed[i];
      if (!contact) continue;
      setRows((prev) => prev.map((r, idx) => (idx === i ? { ...r, status: "sending" } : r)));

      const personalized = text.replaceAll("{name}", contact.name || "");
      try {
        const res = await fetch("/api/broadcast/send", {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
          body: JSON.stringify({ name: contact.name, phone: contact.phone, text: personalized }),
        });
        const data = await res.json();
        setRows((prev) =>
          prev.map((r, idx) =>
            idx === i ? { ...r, status: data.ok ? "sent" : "failed", error: data.ok ? undefined : data.error } : r,
          ),
        );
      } catch (e) {
        setRows((prev) =>
          prev.map((r, idx) => (idx === i ? { ...r, status: "failed", error: e instanceof Error ? e.message : String(e) } : r)),
        );
      }

      if (i < parsed.length - 1 && !stopRef.current) await sleep(DELAY_MS);
    }
    setCountdown(0);
    setRunning(false);
  }

  function stop() {
    stopRef.current = true;
  }

  const parsedCount = parseContacts().length;
  const sent = rows.filter((r) => r.status === "sent").length;
  const failed = rows.filter((r) => r.status === "failed").length;

  const page: React.CSSProperties = { minHeight: "100vh", background: "#eef2f4", padding: "24px 16px" };
  const wrap: React.CSSProperties = { fontFamily: "system-ui, sans-serif", maxWidth: 760, margin: "0 auto", color: "#12242c" };
  const card: React.CSSProperties = { background: "#fff", border: "1px solid #e6ebee", borderRadius: 14, padding: 18, marginBottom: 16 };
  const label: React.CSSProperties = { fontWeight: 600, fontSize: 14, marginBottom: 6, display: "block" };
  const area: React.CSSProperties = { width: "100%", boxSizing: "border-box", padding: 12, borderRadius: 10, border: "1px solid #d5dde1", fontFamily: "inherit", fontSize: 14, resize: "vertical" };
  const btn: React.CSSProperties = { padding: "11px 18px", borderRadius: 10, border: "none", cursor: "pointer", fontWeight: 700, fontSize: 15 };

  if (!token) {
    return (
      <div style={page}>
        <main style={wrap}>
          <h1>Рассылка напоминаний</h1>
          <div style={card}>
            <p style={{ marginTop: 0, color: "#5b6b73" }}>Вход менеджера</p>
            <label style={label}>Email</label>
            <input style={{ ...area, marginBottom: 10 }} value={email} onChange={(e) => setEmail(e.target.value)} />
            <label style={label}>Пароль</label>
            <input style={{ ...area, marginBottom: 14 }} type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
            <button style={{ ...btn, background: "#13b0a0", color: "#fff" }} onClick={login}>Войти</button>
            {loginErr && <p style={{ color: "#c0392b" }}>{loginErr}</p>}
          </div>
        </main>
      </div>
    );
  }

  return (
    <div style={page}>
    <main style={wrap}>
      <h1 style={{ marginBottom: 4 }}>Рассылка напоминаний</h1>
      <p style={{ marginTop: 0, color: "#5b6b73", fontSize: 14 }}>
        Сервисные напоминания пациентам. Между сообщениями пауза 20 c (защита номера от блокировки WhatsApp).
      </p>

      <div style={card}>
        <label style={label}>Текст сообщения (переменная {"{name}"} подставится из списка)</label>
        <textarea style={{ ...area, minHeight: 120 }} value={text} onChange={(e) => setText(e.target.value)} disabled={running} />
      </div>

      <div style={card}>
        <label style={label}>Список контактов — по одному в строке: Имя;+7XXXXXXXXXX</label>
        <textarea
          style={{ ...area, minHeight: 140, fontFamily: "ui-monospace, monospace" }}
          placeholder={"Дархан;+77014004647\nАйгуль;+77771234567"}
          value={contactsRaw}
          onChange={(e) => setContactsRaw(e.target.value)}
          disabled={running}
        />
        <p style={{ fontSize: 13, color: "#5b6b73", margin: "8px 0 0" }}>Распознано контактов: <b>{parsedCount}</b></p>
      </div>

      <div style={{ display: "flex", gap: 10, alignItems: "center", marginBottom: 16 }}>
        {!running ? (
          <button style={{ ...btn, background: "#13b0a0", color: "#fff", opacity: parsedCount ? 1 : 0.5 }} onClick={start} disabled={!parsedCount}>
            Отправить рассылку ({parsedCount})
          </button>
        ) : (
          <button style={{ ...btn, background: "#c0392b", color: "#fff" }} onClick={stop}>Остановить</button>
        )}
        {running && countdown > 0 && <span style={{ color: "#5b6b73" }}>Следующая через {countdown} c…</span>}
        {rows.length > 0 && (
          <span style={{ marginLeft: "auto", fontSize: 14 }}>
            ✅ {sent} &nbsp; ❌ {failed} &nbsp; / {rows.length}
          </span>
        )}
      </div>

      {rows.length > 0 && (
        <div style={card}>
          {rows.map((r, i) => (
            <div key={i} style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 0", borderBottom: i < rows.length - 1 ? "1px solid #eef2f4" : "none" }}>
              <span style={{ width: 22, textAlign: "center" }}>{statusIcon(r.status)}</span>
              <span style={{ flex: 1, minWidth: 0 }}>
                <b>{r.name || "—"}</b> <span style={{ color: "#8894a0" }}>{r.phone}</span>
                {r.error && <span style={{ color: "#c0392b", fontSize: 13 }}> — {r.error}</span>}
              </span>
              <span style={{ fontSize: 13, color: "#8894a0" }}>{statusLabel(r.status)}</span>
            </div>
          ))}
        </div>
      )}
    </main>
    </div>
  );
}

function statusIcon(s: Row["status"]): string {
  return s === "sent" ? "✅" : s === "failed" ? "❌" : s === "sending" ? "⏳" : "•";
}
function statusLabel(s: Row["status"]): string {
  return s === "sent" ? "отправлено" : s === "failed" ? "ошибка" : s === "sending" ? "отправка…" : "ожидает";
}
