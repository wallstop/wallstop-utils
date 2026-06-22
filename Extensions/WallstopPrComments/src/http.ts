export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export class HttpError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly body: string,
  ) {
    super(message);
  }
}

export async function readJsonResponse<T>(response: Response, context: string): Promise<T> {
  const text = await response.text();
  if (!response.ok) {
    throw new HttpError(`${context} failed with HTTP ${response.status}.`, response.status, text);
  }

  if (text.trim() === '') {
    return undefined as T;
  }

  return JSON.parse(text) as T;
}

export function isAuthFailure(error: unknown): boolean {
  return error instanceof HttpError && (error.status === 401 || error.status === 403);
}
