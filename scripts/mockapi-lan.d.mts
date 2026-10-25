/**
 * Types for mockapi-lan.mjs (plain JavaScript for the same reason as
 * guide-images.mjs: it uses node:fs, and the project carries no @types/node).
 */
import type { UserConfig } from 'vite';

export const MOCK_PREFIX: string;
export const MOCK_TARGET: string;
export const ALLOWED_MOCK_PATHS: string[];
export const NO_CLIENT_ENV_PREFIX: string;

/** KEY=VALUE lines of one dotenv file. */
export function parseEnvText(text: string): Record<string, string>;

/** The fabricated anon key, from .env.mockapi alone. Throws when it cannot be sure. */
export function resolveMockapiLanKey(mockapiText: string | null, others?: Array<string | null>): string;

/** Whether a request path under MOCK_PREFIX may be forwarded to the mock. */
export function isAllowedMockPath(urlPath: string): boolean;

/** The dev-server settings for `--mode mockapi-lan`. Throws for a build or an unsafe env. */
export function mockapiLanConfig(command: 'serve' | 'build', read?: (name: string) => string | null): UserConfig;
