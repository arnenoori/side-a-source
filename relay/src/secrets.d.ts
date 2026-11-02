// Worker secrets, which `wrangler types` can't see. Unset in local runs until .dev.vars has them.
interface __BaseEnv_Env {
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  RATE_KEY: string;
}
