/**
 * Mock Wazzup server (ТЗ §27): подменяет fetch, не отправляет реальные
 * WhatsApp-сообщения. Возвращает заранее заданные ответы по (method, path).
 */

export interface MockResponse {
  status: number;
  body?: unknown;
  headers?: Record<string, string>;
}

export interface RecordedRequest {
  method: string;
  url: string;
  path: string;
  body: unknown;
  authorization: string | null;
}

export class MockWazzupServer {
  readonly requests: RecordedRequest[] = [];
  private routes = new Map<string, MockResponse | (() => MockResponse)>();

  /** Зарегистрировать ответ на "METHOD /path". */
  on(route: `${string} ${string}`, response: MockResponse | (() => MockResponse)): this {
    this.routes.set(route, response);
    return this;
  }

  get fetch(): typeof fetch {
    return (async (input: string | URL | Request, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input.toString();
      const method = (init?.method ?? "GET").toUpperCase();
      const path = new URL(url).pathname;
      const headers = new Headers(init?.headers);
      let body: unknown = undefined;
      if (typeof init?.body === "string" && init.body.length > 0) {
        try {
          body = JSON.parse(init.body);
        } catch {
          body = init.body;
        }
      }
      this.requests.push({
        method,
        url,
        path,
        body,
        authorization: headers.get("authorization"),
      });

      const entry = this.routes.get(`${method} ${path}`);
      const resolved = typeof entry === "function" ? entry() : entry;
      const resp = resolved ?? { status: 404, body: { error: "NOT_FOUND" } };

      return new Response(resp.body === undefined ? "" : JSON.stringify(resp.body), {
        status: resp.status,
        headers: { "content-type": "application/json", ...(resp.headers ?? {}) },
      });
    }) as typeof fetch;
  }
}
