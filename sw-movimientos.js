// Service worker de Entradas y salidas de patio (Plataforma HT)
// IMPORTANTE: en Railway la plataforma vive en la raíz del dominio, así que este
// service worker controla TODAS las páginas (index.html, mapa-patios.html, inventario/...).
// Por eso las páginas propias se piden siempre a la red primero; la copia guardada
// solo se usa si no hay conexión (caseta sin señal).
const VERSION = 'mov-v4-2026-10-02';
const CACHE = 'movimientos-ht-' + VERSION;
const EXTERNOS = [
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js',
  'https://fonts.googleapis.com/css2?family=Barlow:wght@400;500;600;700&family=Saira:ital,wght@1,700;1,800&display=swap'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE)
    .then(c => Promise.all(['./movimientos.html', './ht.css', './manifest-movimientos.json', ...EXTERNOS]
      .map(u => c.add(u).catch(() => null))))
    .then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  // Borra las versiones anteriores (incluida la que guardaba index.html para siempre)
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const u = e.request.url;
  // Datos de Supabase: nunca se interceptan
  if (u.includes('/rest/v1/') || u.includes('/auth/v1/') || u.includes('/storage/v1/') || u.includes('/functions/v1/')) return;

  // Librerías y fuentes externas: de la copia guardada (no cambian)
  if (EXTERNOS.some(x => u.startsWith(x))) {
    e.respondWith(caches.match(e.request).then(hit => hit || fetch(e.request)));
    return;
  }

  // Páginas y archivos de la plataforma: SIEMPRE de la red; la copia solo si no hay conexión
  if (u.startsWith(self.location.origin)) {
    const guardar = u.includes('movimientos') || u.includes('ht.css');
    e.respondWith(fetch(e.request).then(res => {
      if (guardar && res.ok) { const copia = res.clone(); caches.open(CACHE).then(c => c.put(e.request, copia)).catch(() => {}); }
      return res;
    }).catch(() => caches.match(e.request)));
  }
});
