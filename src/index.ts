import http from 'http';
import { app } from './app';
import { config } from './config';
import { initSocket } from './socket';
import { query } from './db/pool';
import { SYSTEM_USER_EMAIL } from './constants';

const server = http.createServer(app);
initSocket(server);

server.listen(config.port, async () => {
  console.log(`A/SIDE API listening on port ${config.port}`);

  // Seed a reusable dev invite code so registration is easy during development.
  // The code "testinvite0000" is recreated on every startup if it doesn't
  // already exist.
  if (config.nodeEnv === 'development' || config.devOtp) {
    try {
      // Ensure a sentinel system user exists to own the dev invite.
      // The display_name 'System' shows up nowhere user-facing because
      // every user-listing query filters this row out by email.
      const { rows: systemUsers } = await query(
        `INSERT INTO users (email, username, display_name)
         VALUES ($1, 'system', 'System')
         ON CONFLICT (email) DO UPDATE SET username = 'system'
         RETURNING id`,
        [SYSTEM_USER_EMAIL],
      );
      const systemUserId = systemUsers[0].id;

      // Upsert the dev invite — reset it to pending with a far-future expiry
      await query(
        `INSERT INTO invites (created_by_user_id, code, status, expires_at)
         VALUES ($1, 'testinvite0000', 'pending', NOW() + INTERVAL '10 years')
         ON CONFLICT (code) DO UPDATE SET status = 'pending', expires_at = NOW() + INTERVAL '10 years'`,
        [systemUserId],
      );
      console.log('Dev invite code ready: testinvite0000');
    } catch (err) {
      console.warn('Could not seed dev invite:', err);
    }
  }
});
