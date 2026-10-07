import product from '../public/product.json' with { type: 'json' };
import { latestDownloadableRelease, releaseAPI, releasesURL } from './release.mjs';

export function createAgentTools(fetcher = fetch) {
  return [{
    name: 'get_side_a_info',
    description: 'Read Side A product information, Mac requirements, setup guide, and experimental feature limitations.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true },
    execute: async () => ({ content: [{ type: 'text', text: JSON.stringify(product) }] }),
  }, {
    name: 'check_side_a_download',
    description: 'Check official Side A release availability. Returns a download only for a published stable universal DMG with checksums. Does not download or install anything.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true },
    execute: async () => {
      let result;
      try {
        const response = await fetcher(releaseAPI, { credentials: 'omit', signal: AbortSignal.timeout(7000), headers: { Accept: 'application/vnd.github+json' } });
        if (!response.ok) throw new Error('Release lookup unavailable');
        const release = latestDownloadableRelease(await response.json());
        result = release ? { status: 'available', ...release } : { status: 'coming-soon', releasesURL };
      } catch { result = { status: 'unknown', releasesURL }; }
      return { content: [{ type: 'text', text: JSON.stringify(result) }] };
    },
  }];
}
