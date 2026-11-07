const analyticsAttribute = "lawrelayAnalyticsWebsiteId"
const productionOrigin = "https://lawrelay.be"
const publicPath = /^\/(?:(?:nl|fr|de|en)(?:\/(?:privacy|terms|cookies|legal-notice|court-cover|legal-assignments))?|(?:privacy|terms|cookies|legal-notice|court-cover|legal-assignments)?)\/?$/
const preferenceCookie = "lawrelay_statistics"
const noticeCookie = "lawrelay_cookie_notice"
const preferenceLifetime = 180 * 24 * 60 * 60
const productEvents = new Map([
  ["wetwijzer", "header_wetwijzer_click"],
  ["praxis", "header_praxis_click"]
])
const pendingProductClickLimit = 10

let trackerLoading = false
let trackerReady = false
let trackerWebsiteId = null
let pendingPageview = null
let pendingProductClicks = []
let pageTransitioning = false
let preferencesOpen = false

function privacySignalEnabled() {
  return navigator.globalPrivacyControl === true ||
    navigator.doNotTrack === "1" ||
    window.doNotTrack === "1" ||
    navigator.msDoNotTrack === "1"
}

function timedCookie(name, values) {
  const match = document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]*)`))
  if (!match) return null

  try {
    const parsed = /^(\w+)\.v1\.(\d+)$/.exec(decodeURIComponent(match[1]))
    if (!parsed) return null
    if (!values.includes(parsed[1])) return null

    const recordedAt = Number(parsed[2])
    const now = Date.now()
    if (!Number.isSafeInteger(recordedAt) || recordedAt > now || now - recordedAt >= preferenceLifetime * 1000) return null

    return parsed[1]
  } catch (_) {
    return null
  }
}

function preference() {
  return timedCookie(preferenceCookie, ["allow", "deny"])
}

function statisticsAllowed() {
  return preference() !== "deny" && !privacySignalEnabled()
}

function saveTimedCookie(name, value) {
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  document.cookie = `${name}=${value}.v1.${Date.now()}; Max-Age=${preferenceLifetime}; Path=/; SameSite=Lax${secure}`
}

function dismissBanner() {
  saveTimedCookie(noticeCookie, "seen")
  preferencesOpen = false
  updatePreferencePanel()
}

function preferencePanel() {
  return document.querySelector("[data-analytics-preference-panel]")
}

function publicAnalyticsPage() {
  return !pageTransitioning && Boolean(document.body.dataset[analyticsAttribute] && currentPageview())
}

function updatePreferencePanel() {
  const panel = preferencePanel()
  if (!panel) return

  const status = panel.querySelector("[data-analytics-preference-status]")
  const actions = panel.querySelector("[data-analytics-preference-actions]")
  const alreadyInformed = timedCookie(noticeCookie, ["seen"]) || preference()
  panel.hidden = !preferencesOpen && (Boolean(alreadyInformed) || !publicAnalyticsPage())
  if (actions) actions.hidden = !preferencesOpen
  const currentChoice = statisticsAllowed() ? "allow" : "deny"
  panel.querySelectorAll("[data-analytics-preference]").forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.analyticsPreference === currentChoice))
  })
  if (status) {
    status.hidden = !privacySignalEnabled()
    status.textContent = privacySignalEnabled() ? panel.dataset.analyticsPrivacySignalMessage : ""
  }
}

function currentPageview() {
  const url = new URL(window.location.href)
  if (url.origin !== productionOrigin || !publicPath.test(url.pathname)) return null

  let referrer = ""
  if (document.referrer) {
    try {
      referrer = new URL(document.referrer).origin
    } catch (_) {
      referrer = ""
    }
  }

  return { url: url.pathname.replace(/\/$/, "") || "/", referrer }
}

function sendAnalytics(pageview, name) {
  if (!trackerReady || !window.umami || !pageview || !statisticsAllowed() || !publicAnalyticsPage()) return false
  if (trackerWebsiteId !== document.body.dataset[analyticsAttribute] || currentPageview().url !== pageview.url) return false

  try {
    const request = window.umami.track((payload) => ({
      website: payload.website,
      hostname: payload.hostname,
      language: payload.language,
      screen: payload.screen,
      title: "LawRelay",
      url: pageview.url,
      referrer: pageview.referrer,
      ...(name ? { name } : {})
    }))
    request?.catch?.(() => {})
    return true
  } catch (_) {
    return false
  }
}

function loadTracker(websiteId) {
  if (trackerLoading || trackerReady) return

  trackerLoading = true
  trackerWebsiteId = websiteId
  const script = document.createElement("script")
  script.defer = true
  script.src = "https://analytics.lawrelay.be/script.js"
  script.dataset.websiteId = websiteId
  script.dataset.autoTrack = "false"
  script.dataset.doNotTrack = "true"
  script.dataset.domains = "lawrelay.be"
  script.onload = () => {
    trackerReady = true
    trackerLoading = false
    if (statisticsAllowed() && publicAnalyticsPage()) {
      sendAnalytics(pendingPageview)
      const queued = pendingProductClicks
      pendingProductClicks = []
      queued.forEach((click) => {
        if (click.websiteId === document.body.dataset[analyticsAttribute]) sendAnalytics(click.pageview, click.name)
      })
    }
    clearPendingTracking()
  }
  script.onerror = () => {
    trackerLoading = false
    clearPendingTracking()
  }
  document.head.append(script)
}

function clearPendingTracking() {
  pendingPageview = null
  pendingProductClicks = []
}

function trackPublicPage() {
  clearPendingTracking()
  pageTransitioning = false
  preferencesOpen = false
  updatePreferencePanel()
  if (!statisticsAllowed()) return

  const websiteId = document.body.dataset[analyticsAttribute]
  const pageview = currentPageview()
  if (!websiteId || !pageview) return

  if (!sendAnalytics(pageview)) {
    pendingPageview = pageview
    loadTracker(websiteId)
  }
}

function trackProductLink(event) {
  if (event.defaultPrevented) return
  if (event.type === "click" ? event.button !== 0 : event.type !== "auxclick" || event.button !== 1) return

  const link = event.target.closest("a[data-lawrelay-product]")
  const name = productEvents.get(link?.dataset.lawrelayProduct)
  if (!name || !link.closest(".product-bar") || !statisticsAllowed() || !publicAnalyticsPage()) return

  const pageview = currentPageview()
  const websiteId = document.body.dataset[analyticsAttribute]
  if (trackerReady) {
    sendAnalytics(pageview, name)
  } else if (pendingProductClicks.length < pendingProductClickLimit) {
    pendingProductClicks.push({ name, pageview, websiteId })
    loadTracker(websiteId)
  }
}

document.addEventListener("turbo:before-visit", () => {
  pageTransitioning = true
  clearPendingTracking()
})
document.addEventListener("turbo:load", trackPublicPage)
document.addEventListener("click", (event) => {
  const choice = event.target.closest("[data-analytics-preference]")?.dataset.analyticsPreference
  if (["allow", "deny"].includes(choice)) {
    const wasAllowed = statisticsAllowed()
    saveTimedCookie(preferenceCookie, choice)
    dismissBanner()
    if (choice === "deny") clearPendingTracking()
    else if (!wasAllowed) trackPublicPage()
    return
  }

  if (event.target.closest("[data-analytics-dismiss-banner]")) {
    dismissBanner()
    return
  }

  const trigger = event.target.closest("[data-analytics-open-preferences]")
  if (trigger) {
    const panel = preferencePanel()
    if (!panel) return

    preferencesOpen = true
    updatePreferencePanel()
    panel.querySelector('[data-analytics-preference][aria-pressed="true"]')?.focus()
    return
  }

  trackProductLink(event)
})
document.addEventListener("auxclick", trackProductLink)
