import { describe, expect, it } from 'vitest';
import { errorBody, retryable } from '../src/errors';

describe('error envelope', () => {
  it('marks only 429 and 503 retryable, as the protocol says', () => {
    for (const status of [429, 503]) expect(retryable(status)).toBe(true);
    for (const status of [400, 401, 404, 409, 500, 502, 504]) expect(retryable(status), String(status)).toBe(false);
  });

  it('carries the code, message and retryable flag', () => {
    expect(errorBody(503, 'paused', 'Sending is paused')).toEqual({ error: { code: 'paused', message: 'Sending is paused', retryable: true } });
    expect(errorBody(500, 'broken', 'No').error.retryable).toBe(false);
  });
});
