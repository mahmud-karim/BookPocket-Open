import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({
  plugins: [react()],
  server: {
    strictPort: true,
    proxy: { "/v1": { target: "http://127.0.0.1:8782", changeOrigin: false } },
  },
  build: { sourcemap: true },
});
