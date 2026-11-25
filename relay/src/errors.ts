/** Only what a client can fix by asking again: too many requests (429) and a relay that is paused or unconfigured (503).
 *  Every other status, a 500 included, is a fault a retry will not cure. Same rule as the Mac's server and the phone
 *  (docs/remote/protocol.md, "retryable"). */
export const retryable = (status: number): boolean => status === 429 || status === 503;

/** The body of an error response: protocol's envelope, `{"error": {"code", "message", "retryable"}}`. */
export const errorBody = (status: number, code: string, message: string) => ({ error: { code, message, retryable: retryable(status) } });
