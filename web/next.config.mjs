/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Пакеты, которые должны исполняться только на сервере (не бандлиться в клиент).
  serverExternalPackages: ["bullmq", "ioredis", "@prisma/client"],
};

export default nextConfig;
