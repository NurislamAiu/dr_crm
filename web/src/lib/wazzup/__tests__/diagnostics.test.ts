import { test, expect } from "vitest";
import { webhookMatchesAppUrl } from "../diagnostics";

test("webhookMatchesAppUrl: совпадение origin+path (секрет в query игнорируется)", () => {
  expect(
    webhookMatchesAppUrl(
      "https://abc.trycloudflare.com/api/webhooks/wazzup?secret=xyz",
      "https://abc.trycloudflare.com",
    ),
  ).toBe(true);
});

test("webhookMatchesAppUrl: хвостовой слэш в APP_URL не мешает", () => {
  expect(
    webhookMatchesAppUrl(
      "https://abc.trycloudflare.com/api/webhooks/wazzup?secret=xyz",
      "https://abc.trycloudflare.com/",
    ),
  ).toBe(true);
});

test("webhookMatchesAppUrl: устаревший адрес туннеля → расхождение", () => {
  expect(
    webhookMatchesAppUrl(
      "https://OLD.trycloudflare.com/api/webhooks/wazzup?secret=xyz",
      "https://NEW.trycloudflare.com",
    ),
  ).toBe(false);
});

test("webhookMatchesAppUrl: другой путь → расхождение", () => {
  expect(
    webhookMatchesAppUrl(
      "https://abc.trycloudflare.com/wrong/path",
      "https://abc.trycloudflare.com",
    ),
  ).toBe(false);
});

test("webhookMatchesAppUrl: null/пустые значения безопасны", () => {
  expect(webhookMatchesAppUrl(null, "https://abc.com")).toBe(false);
  expect(webhookMatchesAppUrl("https://abc.com/api/webhooks/wazzup", null)).toBe(false);
  expect(webhookMatchesAppUrl(undefined, null)).toBe(false);
});

test("webhookMatchesAppUrl: некорректный URL не бросает исключение", () => {
  expect(webhookMatchesAppUrl("не-url", "https://abc.com")).toBe(false);
});
