/**
 * Supabase helper utilities.
 *
 * Supabase JS client v2 returns thenables (PromiseLike objects), not true Promises.
 * Direct `await` on these thenables can silently fail to resolve in some
 * environments. These helpers normalize thenables into true Promises with
 * optional timeouts and error surfacing.
 */

/**
 * Wrap a Supabase thenable (or any thenable) in a true Promise.
 * Optionally apply a timeout — rejects if the operation exceeds `ms`.
 */
export async function withTimeout<T>(
  thenable: PromiseLike<T> | Promise<T>,
  ms: number = 10000,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`Operation timed out after ${ms}ms`)),
      ms,
    );
    Promise.resolve(thenable)
      .then((result: T) => {
        clearTimeout(timer);
        resolve(result);
      })
      .catch((err: unknown) => {
        clearTimeout(timer);
        reject(err);
      });
  });
}

/**
 * Call a Supabase auth method, normalize the thenable into a Promise,
 * and apply a timeout. Returns the raw result object so callers can
 * inspect `{ error, data, ... }` as they normally would.
 */
export async function authCall<T>(
  thenable: PromiseLike<{
    error: { message: string; status?: number } | null;
    data?: T;
  }>,
  ms: number = 10000,
): Promise<{ error: { message: string; status?: number } | null; data?: T }> {
  return withTimeout(thenable, ms) as Promise<{
    error: { message: string; status?: number } | null;
    data?: T;
  }>;
}
