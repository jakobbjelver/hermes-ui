import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'
import path from 'path'

export default defineConfig({
  base: './',
  // Per-build id, read by the React Query persistence layer as a cache buster so
  // a redeploy (or dev restart) drops any persisted query blob whose data shape
  // may have changed.
  define: {
    __HERMES_BUILD_ID__: JSON.stringify(String(Date.now()))
  },
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: 'autoUpdate',
      injectRegister: null,
      manifest: {
        name: 'Hermes',
        short_name: 'Hermes',
        description: 'A UI for the Hermes agent.',
        display: 'standalone',
        start_url: '.',
        scope: '.',
        background_color: '#111111',
        theme_color: '#0a0a0a',
        icons: [
          { src: 'hermes.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
          { src: 'hermes.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
          { src: 'hermes.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' }
        ]
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,woff,woff2,ttf,otf,eot,png,jpg,jpeg,svg,gif,webp,ico}'],
        maximumFileSizeToCacheInBytes: 32 * 1024 * 1024,
        navigateFallback: 'index.html',
        navigateFallbackDenylist: [/^\/api/, /^\/auth/, /^\/login/]
      },
      devOptions: {
        enabled: false
      }
    })
  ],
  css: {
    postcss: { plugins: [] }
  },
  build: {
    chunkSizeWarningLimit: 4000,
    rolldownOptions: {
      output: {
        codeSplitting: {
          groups: [
            {
              name: 'react-vendor',
              test: /[\\/]node_modules[\\/](react|react-dom|scheduler)[\\/]/,
              priority: 10
            }
          ]
        }
      }
    }
  },
  optimizeDeps: {
    // driver.js only enters the graph through the tour tool's dynamic import
    // chain as a `?raw` IIFE import. Letting esbuild prebundle it would rewrite
    // the raw-text transform and break it ("does not provide an export named
    // 'default'"). Query and bare forms all listed — exclusion matches exact ids.
    exclude: [
      'driver.js',
      'driver.js/dist/driver.js.iife.js',
      'driver.js/dist/driver.js.iife.js?raw',
      'driver.js/dist/driver.css?raw'
    ]
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
      '@hermes/shared': path.resolve(__dirname, '../shared/src'),
      // The tour tool injects driver.js's prebuilt IIFE into the preview pane's
      // guest page as raw source. driver.js's exports map doesn't expose that
      // dist file, so alias the subpath straight to it on disk. Both keys on
      // purpose: alias matching is exact, and the id reaches the resolver with
      // the `?raw` query attached in dev but stripped in some build paths.
      'driver.js/dist/driver.js.iife.js?raw': `${path.resolve(
        __dirname,
        'node_modules/driver.js/dist',
        'driver.js.iife.js'
      )}?raw`,
      'driver.js/dist/driver.js.iife.js': path.resolve(
        __dirname,
        'node_modules/driver.js/dist',
        'driver.js.iife.js'
      )
    },
    dedupe: ['react', 'react-dom']
  },
  server: {
    host: '127.0.0.1',
    port: 5174,
    strictPort: true
  },
  preview: {
    host: '127.0.0.1',
    port: 4174
  }
})
