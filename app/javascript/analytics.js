const analyticsAttribute = "lawrelayAnalyticsWebsiteId"
const publicPath = /^\/(?:(?:nl|fr|de|en)(?:\/(?:privacy|terms|cookies|legal-notice))?|(?:privacy|terms|cookies|legal-notice)?)\/?$/
const preferenceCookie = "lawrelay_statistics"
const preferenceLifetime = 180 * 24 * 60 * 60

let trackerLoading = false
let trackerReady = false
let pendingPageview = null

function privacySignalEnabled() {
  return navigator.globalPrivacyControl === true ||
    navigator.doNotTrack === "1" ||
    window.doNotTrack === "1" ||
    navigator.msDoNotTrack === "1"
}

function preference() {
  const match = document.cookie.match(new RegExp(`(?:^|; )${preferenceCookie}=([^;]*)`))
  if (!match) return null

  try {
    const parsed = /^(allow|deny)\.v1\.(\d+)$/.exec(decodeURIComponent(match[1]))
    if (!parsed) return null

    const recordedAt = Number(parsed[2])
    const now = Date.now()
    if (!Number.isSafeInteger(recordedAt) || recordedAt > now || now - recordedAt >= preferenceLifetime * 1000) return null

    return parsed[1]
  } catch (_) {
    return null
  }
}

function statisticsAllowed() {
  return preference() === "allow" && !privacySignalEnabled()
}

function savePreference(value) {
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  document.cookie = `${preferenceCookie}=${value}.v1.${Date.now()}; Max-Age=${preferenceLifetime}; Path=/; SameSite=Lax${secure}`
}

function preferencePanel() {
  return document.querySelector("[data-analytics-preference-panel]")
}

function publicAnalyticsPage() {
  return Boolean(document.body.dataset[analyticsAttribute] && currentPageview())
}

function updatePreferencePanel() {
  const panel = preferencePanel()
  if (!panel) return

  const status = panel.querySelector("[data-analytics-preference-status]")
  panel.hidden = preference() === "allow" || preference() === "deny" || !publicAnalyticsPage()
  if (status) {
    status.hidden = !privacySignalEnabled()
    status.textContent = privacySignalEnabled() ? panel.dataset.analyticsPrivacySignalMessage : ""
  }
}

function currentPageview() {
  const url = new URL(window.location.href)
  if (!publicPath.test(url.pathname)) return null

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

function sendPageview(pageview) {
  if (!trackerReady || !window.umami || !pageview) return false

  try {
    window.umami.track((payload) => ({
      website: payload.website,
      hostname: payload.hostname,
      language: payload.language,
      screen: payload.screen,
      title: "LawRelay",
      url: pageview.url,
      referrer: pageview.referrer
    }))
    return true
  } catch (_) {
    return false
  }
}

function loadTracker(websiteId) {
  if (trackerLoading || trackerReady) return

  trackerLoading = true
  const script = document.createElement("script")
  script.defer = true
  script.src = "https://analytics.lawrelay.be/script.js"
  script.dataset.websiteId = websiteId
  script.dataset.autoTrack = "false"
  script.dataset.doNotTrack = "true"
  script.onload = () => {
    trackerReady = true
    trackerLoading = false
    if (statisticsAllowed() && currentPageview() && document.body.dataset[analyticsAttribute]) {
      sendPageview(pendingPageview)
    }
    pendingPageview = null
  }
  script.onerror = () => { trackerLoading = false }
  document.head.append(script)
}

function trackPublicPage() {
  pendingPageview = null
  updatePreferencePanel()
  if (!statisticsAllowed()) return

  const websiteId = document.body.dataset[analyticsAttribute]
  const pageview = currentPageview()
  if (!websiteId || !pageview) return

  if (!sendPageview(pageview)) {
    pendingPageview = pageview
    loadTracker(websiteId)
  }
}

document.addEventListener("turbo:load", trackPublicPage)
document.addEventListener("click", (event) => {
  const choice = event.target.closest("[data-analytics-preference]")?.dataset.analyticsPreference
  if (choice) {
    savePreference(choice)
    updatePreferencePanel()
    if (choice === "allow") trackPublicPage()
    else pendingPageview = null
    return
  }

  const trigger = event.target.closest("[data-analytics-open-preferences]")
  if (trigger) {
    const panel = preferencePanel()
    if (!panel) return

    panel.hidden = false
    panel.querySelector("[data-analytics-preference]")?.focus()
  }
})
