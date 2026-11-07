const dismissalKey = "lawrelay_pwa_install_dismissed_at_v1"
const dismissalLifetime = 30 * 24 * 60 * 60 * 1000

let deferredPrompt = null
let dismissedAt = null
let installedHere = false
let explicit = false
let registrationPending = false
let registered = false
let explicitTrigger = null

function banner() {
  return document.querySelector("[data-pwa-install-banner]")
}

function available() {
  const manifest = document.querySelector('link[rel="manifest"]')
  if (!manifest || !banner() || window.isSecureContext !== true) return false

  try {
    return new URL(manifest.href, window.location.href).origin === window.location.origin
  } catch (_) {
    return false
  }
}

function standalone() {
  return window.matchMedia?.("(display-mode: standalone)").matches === true || navigator.standalone === true
}

function ios() {
  return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
}

function iosSafari() {
  return ios() && /WebKit/.test(navigator.userAgent) && !/CriOS|FxiOS|EdgiOS|OPiOS/.test(navigator.userAgent)
}

function recentDismissal() {
  let value = dismissedAt
  try {
    const saved = window.localStorage.getItem(dismissalKey)
    if (saved !== null) value = Number(saved)
  } catch (_) {}

  const age = Date.now() - value
  const valid = Number.isSafeInteger(value) && value > 0 && age >= 0 && age < dismissalLifetime
  if (!valid) clearDismissal()
  return valid
}

function clearDismissal() {
  dismissedAt = null
  try { window.localStorage.removeItem(dismissalKey) } catch (_) {}
}

function rememberDismissal() {
  dismissedAt = Date.now()
  try { window.localStorage.setItem(dismissalKey, String(dismissedAt)) } catch (_) {}
}

function cookiePanel() {
  const panel = document.querySelector("[data-analytics-preference-panel]")
  return panel && !panel.hidden ? panel : null
}

function hide() {
  const panel = banner()
  if (panel) panel.hidden = true
}

function dismiss() {
  const trigger = explicitTrigger
  explicitTrigger = null
  rememberDismissal()
  explicit = false
  hide()
  trigger?.focus?.()
}

function manualMode() {
  if (ios()) return "ios"
  if (/Mac/.test(navigator.platform) && /Safari/.test(navigator.userAgent) && !/Chrome|Chromium|Edg\//.test(navigator.userAgent)) return "safari"
  if (/Android/.test(navigator.userAgent)) return "android"
  return "manual"
}

function show(mode) {
  const panel = banner()
  if (!panel) return

  panel.querySelectorAll("[data-pwa-copy]").forEach((copy) => { copy.hidden = copy.dataset.pwaCopy !== mode })
  panel.querySelector("[data-pwa-install]").hidden = mode !== "native"
  const privacyPanel = cookiePanel()
  const offset = privacyPanel ? Math.ceil(privacyPanel.getBoundingClientRect().height) + 24 : 12
  panel.style.setProperty("--pwa-bottom-offset", `${offset}px`)
  panel.hidden = false
}

function refresh() {
  const eligible = available()
  const installed = standalone() || installedHere
  document.querySelectorAll("[data-pwa-open-install]").forEach((button) => { button.hidden = !eligible || installed })
  if (!eligible || installed) return hide()
  if (explicit) return show(deferredPrompt ? "native" : manualMode())
  if (recentDismissal() || cookiePanel()) return hide()
  if (deferredPrompt) return show("native")
  if (iosSafari()) return show("ios")
  hide()
}

function registerServiceWorker() {
  if (registered || registrationPending || document.readyState !== "complete" || !available() || !("serviceWorker" in navigator)) return

  const worker = new URL(banner().dataset.serviceWorkerUrl, window.location.href)
  if (worker.origin !== window.location.origin || worker.pathname !== "/service-worker.js" || worker.search || worker.hash) return

  registrationPending = true
  try {
    Promise.resolve(navigator.serviceWorker.register(worker.href, { scope: "/", updateViaCache: "none" }))
      .then(() => { registered = true })
      .catch(() => {})
      .finally(() => { registrationPending = false })
  } catch (_) {
    registrationPending = false
  }
}

function install() {
  const prompt = deferredPrompt
  if (!prompt || !available() || standalone() || installedHere) return refresh()

  deferredPrompt = null
  explicit = false
  hide()
  try {
    // The native prompt must start in this click's user activation, before any await.
    Promise.resolve(prompt.prompt()).catch(() => {
      explicit = true
      refresh()
    })
    Promise.resolve(prompt.userChoice).then((choice) => {
      if (choice?.outcome === "dismissed") rememberDismissal()
      if (choice?.outcome === "accepted") {
        installedHere = true
        clearDismissal()
      }
      refresh()
    }).catch(() => {})
  } catch (_) {
    explicit = true
    refresh()
  }
}

window.addEventListener("beforeinstallprompt", (event) => {
  if (!available()) return
  event.preventDefault()
  deferredPrompt = event
  installedHere = false
  refresh()
})

window.addEventListener("appinstalled", () => {
  deferredPrompt = null
  installedHere = true
  explicit = false
  clearDismissal()
  refresh()
})

document.addEventListener("click", (event) => {
  if (event.target?.closest?.("[data-pwa-dismiss]")) {
    dismiss()
  } else if (event.target?.closest?.("[data-pwa-install]")) {
    install()
  } else if (event.target?.closest?.("[data-pwa-open-install]")) {
    explicitTrigger = event.target.closest("[data-pwa-open-install]")
    explicit = true
    refresh()
    const panel = banner()
    if (panel && !panel.hidden) panel.querySelector(deferredPrompt ? "[data-pwa-install]" : "[data-pwa-dismiss]").focus()
  } else {
    refresh()
  }
})

document.addEventListener("keydown", (event) => {
  if (!event.defaultPrevented && event.key === "Escape" && banner() && !banner().hidden) {
    dismiss()
  }
})

document.addEventListener("turbo:before-cache", () => {
  explicit = false
  explicitTrigger = null
  hide()
})

function ready() {
  refresh()
  registerServiceWorker()
}

window.addEventListener("load", ready)
window.addEventListener("resize", refresh)
window.matchMedia?.("(display-mode: standalone)").addEventListener?.("change", refresh)
document.addEventListener("turbo:load", ready)
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", ready, { once: true })
else ready()
