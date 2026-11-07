// Installation only. Requests use the network normally; no page or account
// content is stored by this worker.
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))
