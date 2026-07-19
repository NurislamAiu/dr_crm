import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

export default defineConfig({
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
    // БД/Redis-зависимые тесты помечаем и исключаем из обычного прогона.
    exclude: ["**/node_modules/**", "src/**/*.itest.ts"],
  },
});
