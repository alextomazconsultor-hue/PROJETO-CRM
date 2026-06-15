const CACHE_NAME = '3ps-crm-v1';
const ASSETS = [
  '/3PS-CRM-IMOBILIARIO/',
  '/3PS-CRM-IMOBILIARIO/index.html',
  '/3PS-CRM-IMOBILIARIO/manifest.json'
];

// Instala e faz cache dos arquivos principais
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(ASSETS)).catch(() => {})
  );
  self.skipWaiting();
});

// Ativa e limpa caches antigos
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Estratégia: network first, fallback para cache
self.addEventListener('fetch', e => {
  // Ignora requests do Supabase (sempre online)
  if (e.request.url.includes('supabase.co') || e.request.url.includes('fonts.')) return;

  e.respondWith(
    fetch(e.request)
      .then(res => {
        const clone = res.clone();
        caches.open(CACHE_NAME).then(cache => cache.put(e.request, clone));
        return res;
      })
      .catch(() => caches.match(e.request))
  );
});
