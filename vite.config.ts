/// <reference types="vitest/config" />
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { guideImages } from './scripts/guide-images.mjs';
import { mockapiLanConfig } from './scripts/mockapi-lan.mjs';

// https://vite.dev/config/
export default defineConfig(({ command, mode }) => ({
  // guideImages publishes the user guide screenshots, which are neither in
  // public/ nor reachable from the module graph and were therefore missing
  // from every production build. See scripts/guide-images.mjs.
  plugins: [react(), guideImages()],
  // P8-mobile-1: `--mode mockapi-lan` (dev server only) lets a phone on the
  // home LAN use the loopback mock API through a same-origin proxy. Every other
  // mode, and every build, gets nothing from it. See scripts/mockapi-lan.mjs.
  ...(mode === 'mockapi-lan' ? mockapiLanConfig(command) : {}),
  test: {
    globals: true,
    environment: 'node',
  },
}));
