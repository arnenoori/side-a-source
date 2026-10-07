import config from './analytics-config.json';
import { createAnalytics } from './analytics-core.mjs';

// Access to storage itself can throw in restricted browsing contexts.
let storage: Storage | undefined;
try { storage = window.localStorage; } catch { /* Analytics disabled below. */ }
export const analytics = createAnalytics({
  ...config, location: window.location, navigator: window.navigator, storage,
  randomUUID: () => crypto.randomUUID(), fetch: window.fetch.bind(window),
});
if (!storage) analytics.setDisabled(true);
