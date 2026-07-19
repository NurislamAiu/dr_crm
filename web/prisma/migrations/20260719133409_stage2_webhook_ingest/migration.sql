-- CreateEnum
CREATE TYPE "WebhookEventStatus" AS ENUM ('received', 'processing', 'processed', 'failed');

-- CreateTable
CREATE TABLE "WazzupWebhookEvent" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL DEFAULT 'default',
    "payloadSha256" TEXT NOT NULL,
    "rawPayload" JSONB NOT NULL,
    "isTest" BOOLEAN NOT NULL DEFAULT false,
    "messageCount" INTEGER NOT NULL DEFAULT 0,
    "statusCount" INTEGER NOT NULL DEFAULT 0,
    "channelUpdateCount" INTEGER NOT NULL DEFAULT 0,
    "status" "WebhookEventStatus" NOT NULL DEFAULT 'received',
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "error" TEXT,
    "receivedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "processedAt" TIMESTAMP(3),

    CONSTRAINT "WazzupWebhookEvent_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "InboundMessageReceipt" (
    "id" TEXT NOT NULL,
    "organizationId" TEXT NOT NULL DEFAULT 'default',
    "provider" TEXT NOT NULL DEFAULT 'wazzup',
    "externalMessageId" TEXT NOT NULL,
    "channelId" TEXT NOT NULL,
    "chatType" TEXT NOT NULL,
    "chatId" TEXT NOT NULL,
    "direction" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "hasContent" BOOLEAN NOT NULL DEFAULT false,
    "isEdited" BOOLEAN NOT NULL DEFAULT false,
    "isDeleted" BOOLEAN NOT NULL DEFAULT false,
    "providerDateTime" TIMESTAMP(3),
    "webhookEventId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "InboundMessageReceipt_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "WazzupWebhookEvent_status_idx" ON "WazzupWebhookEvent"("status");

-- CreateIndex
CREATE INDEX "WazzupWebhookEvent_receivedAt_idx" ON "WazzupWebhookEvent"("receivedAt");

-- CreateIndex
CREATE UNIQUE INDEX "WazzupWebhookEvent_organizationId_payloadSha256_key" ON "WazzupWebhookEvent"("organizationId", "payloadSha256");

-- CreateIndex
CREATE INDEX "InboundMessageReceipt_organizationId_channelId_chatId_idx" ON "InboundMessageReceipt"("organizationId", "channelId", "chatId");

-- CreateIndex
CREATE UNIQUE INDEX "InboundMessageReceipt_provider_externalMessageId_key" ON "InboundMessageReceipt"("provider", "externalMessageId");

-- AddForeignKey
ALTER TABLE "InboundMessageReceipt" ADD CONSTRAINT "InboundMessageReceipt_webhookEventId_fkey" FOREIGN KEY ("webhookEventId") REFERENCES "WazzupWebhookEvent"("id") ON DELETE SET NULL ON UPDATE CASCADE;
