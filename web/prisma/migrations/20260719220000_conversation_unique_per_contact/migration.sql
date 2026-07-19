-- Один диалог на контакт: исключает дубли чатов при гонке входящих.
CREATE UNIQUE INDEX "Conversation_organizationId_contactId_key" ON "Conversation"("organizationId", "contactId");
