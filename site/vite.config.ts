import { defineConfig } from 'vite';
export default defineConfig({
  base: './',
  build: { rollupOptions: { input: { main: 'index.html', how: 'how/index.html' } } },
});
