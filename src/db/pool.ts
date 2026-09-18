import { Pool, QueryResult, QueryResultRow } from 'pg';
import { config } from '../config';
import { measureDb } from '../performance';

export const pool = new Pool({
  connectionString: config.databaseUrl,
});

export async function query<T extends QueryResultRow = any>(
  text: string,
  params?: any[],
): Promise<QueryResult<T>> {
  const end = measureDb('query');
  try {
    const result = await pool.query<T>(text, params);
    end(true);
    return result;
  } catch (error) { end(false); throw error; }
}

export async function getClient() {
  const end = measureDb('pool');
  try { const client = await pool.connect(); end(true); return client; }
  catch (error) { end(false); throw error; }
}
