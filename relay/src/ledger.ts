// What has to hold across installs and locations, one small object per fact, named by the caller:
// `registrations:<day>:<network>` and `token:<SHA-256 of a Live Activity token>`.
import { DurableObject } from 'cloudflare:workers';

export const CLAIM_LIFETIME = 14 * 86_400_000;
const DAY = 86_400_000;

interface Claim {
  owner: string;
  seen: number;
}

export class Ledger extends DurableObject<Env> {
  async registrations(): Promise<number> {
    return await this.ctx.storage.get<number>('count') ?? 0;
  }

  async registered(dayEnds: number): Promise<void> {
    await this.ctx.storage.put('count', await this.registrations() + 1);
    await this.ctx.storage.setAlarm(dayEnds + DAY);
  }

  // APNs can't challenge a Live Activity token, and Apple doesn't link it to the device token. So the first
  // proven device token to use one holds it: a device that never held it is refused, however it learned it.
  // `owner` is a hash, and a claim left unused lapses, so a phone whose device token changed gets back in.
  async claim(owner: string, now: number): Promise<boolean> {
    const held = await this.ctx.storage.get<Claim>('claim');
    const live = held !== undefined && now - held.seen <= CLAIM_LIFETIME;
    if (live && held.owner !== owner) return false;
    if (!live || now - held.seen > DAY) {
      await this.ctx.storage.put('claim', { owner, seen: now } satisfies Claim);
      await this.ctx.storage.setAlarm(now + CLAIM_LIFETIME + DAY);
    }
    return true;
  }

  async alarm() {
    await this.ctx.storage.deleteAll();
  }
}
