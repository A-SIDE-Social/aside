type OperationalFields = Record<string, unknown>;

/**
 * Emit a single-line JSON event that survives Docker log collection and is
 * easy to filter without exposing request bodies or other user-provided data.
 */
export function logOperationalEvent(
  event: string,
  outcome: string,
  fields: OperationalFields = {},
): void {
  console.info(JSON.stringify({
    timestamp: new Date().toISOString(),
    event,
    outcome,
    ...fields,
  }));
}
