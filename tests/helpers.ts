import http from 'http';
import fs from 'fs';
import path from 'path';
import { app } from '../src/app';
import { pool, query } from '../src/db/pool';
import { initSocket } from '../src/socket';
import { generateAccessToken } from '../src/middleware/auth';

export { app, pool, query, generateAccessToken };

let server: http.Server;

// Helper to create a user directly in the DB and get a token
export async function createTestUser(overrides: Partial<{
  display_name: string;
  phone_e164: string;
  subscription_status: string;
}> = {}) {
  const autoUsername = `u${Math.random().toString(36).slice(2, 18)}`;
  const displayName = overrides.display_name || `Test User ${Math.random().toString(36).slice(2, 6)}`;
  const { rows } = await query(
    `INSERT INTO users (username, display_name, phone_e164, subscription_status)
     VALUES ($1, $2, $3, $4)
     RETURNING *`,
    [
      autoUsername,
      displayName,
      overrides.phone_e164 || `+1${Math.floor(Math.random() * 9000000000 + 1000000000)}`,
      overrides.subscription_status || 'free',
    ],
  );
  const user = rows[0];
  const token = generateAccessToken(user.id);
  return { user, token };
}

// Helper to create mutual follow between two users
export async function createMutualFollow(userAId: string, userBId: string) {
  await query(
    `INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2), ($2, $1)
     ON CONFLICT DO NOTHING`,
    [userAId, userBId],
  );
}

export function setupTestServer() {
  beforeAll(async () => {
    await query(`
      DROP SCHEMA public CASCADE;
      CREATE SCHEMA public;
      GRANT ALL ON SCHEMA public TO public;
    `);

    // Run all migrations in order
    const migrationsDir = path.join(__dirname, '../src/db/migrations');
    const migrationFiles = fs.readdirSync(migrationsDir)
      .filter((f: string) => f.endsWith('.sql'))
      .sort();
    for (const file of migrationFiles) {
      const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
      await query(sql);
    }

    server = http.createServer(app);
    initSocket(server);
    await new Promise<void>((resolve) => server.listen(0, resolve));
  });

  afterAll(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await pool.end();
  });
}
