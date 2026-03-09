-- CreateTable
CREATE TABLE "AgentInfo" (
    "key" TEXT NOT NULL PRIMARY KEY,
    "value" TEXT NOT NULL,
    "updatedAt" DATETIME NOT NULL
);

-- CreateTable
CREATE TABLE "CpuUsage" (
    "idx" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "timestamp" BIGINT NOT NULL,
    "peak" REAL NOT NULL,
    "average" REAL NOT NULL,
    "min" REAL NOT NULL,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- CreateTable
CREATE TABLE "MemoryUsage" (
    "idx" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "timestamp" BIGINT NOT NULL,
    "peak" REAL NOT NULL,
    "average" REAL NOT NULL,
    "min" REAL NOT NULL,
    "totalMemory" REAL NOT NULL,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- CreateIndex
CREATE INDEX "CpuUsage_timestamp_idx" ON "CpuUsage"("timestamp");

-- CreateIndex
CREATE INDEX "MemoryUsage_timestamp_idx" ON "MemoryUsage"("timestamp");
