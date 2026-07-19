import { test, expect } from "vitest";
import { hashPassword, verifyPassword } from "../password";
import { signJwt, verifyJwt } from "../jwt";

test("password: hash и verify", () => {
  const h = hashPassword("secret123");
  expect(verifyPassword("secret123", h)).toBe(true);
  expect(verifyPassword("wrong", h)).toBe(false);
  expect(verifyPassword("secret123", null)).toBe(false);
});

test("jwt: sign и verify возвращают payload", () => {
  const token = signJwt({ sub: "u1", org: "o1", role: "manager", name: "A" }, "sekret");
  const payload = verifyJwt(token, "sekret");
  expect(payload?.sub).toBe("u1");
  expect(payload?.org).toBe("o1");
  expect(payload?.role).toBe("manager");
});

test("jwt: неверный секрет → null", () => {
  const token = signJwt({ sub: "u1", org: "o1", role: "manager" }, "sekret");
  expect(verifyJwt(token, "other")).toBeNull();
});

test("jwt: истёкший токен → null", () => {
  const token = signJwt({ sub: "u1", org: "o1", role: "manager" }, "sekret", -10);
  expect(verifyJwt(token, "sekret")).toBeNull();
});

test("jwt: испорченный токен → null", () => {
  expect(verifyJwt("not.a.jwt", "sekret")).toBeNull();
  expect(verifyJwt("abc", "sekret")).toBeNull();
});
