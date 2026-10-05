import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { getPostgresPool } from "../src/db/postgresPool.js";

/// Applies schema.sql against DATABASE_URL. Idempotent — every DDL uses
/// IF NOT EXISTS, so this can be re-run on each deploy without breaking.
async function main() {
    const schemaPath = fileURLToPath(new URL("../schema.sql", import.meta.url));
    const sql = await readFile(schemaPath, "utf8");
    const pool = getPostgresPool();
    if (!pool) {
        console.error("DATABASE_URL not configured — set it before running migrate");
        process.exit(2);
    }
    try {
        await pool.query(sql);
        console.log("Match Point schema applied.");
    } finally {
        await pool.end();
    }
}

main().catch((error) => {
    console.error("migrate failed:", error.message);
    process.exit(1);
});
