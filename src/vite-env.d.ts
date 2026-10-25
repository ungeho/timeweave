/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string;
  /**
   * The public origin to build canonical and hreflang URLs from, e.g.
   * "https://example.com". OPTIONAL: left unset, a page canonicalises to
   * wherever it is served from, which is right for a single-origin
   * deployment. Set it when the same build answers on several hostnames --
   * preview deployments, say -- so they do not each claim to be their own
   * site. A local address is never published as a canonical either way.
   */
  readonly VITE_PUBLIC_ORIGIN?: string;
  readonly VITE_SUPABASE_ANON_KEY: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
