import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import vm from "node:vm"

const trackerSource = readFileSync(new URL("../../app/javascript/analytics.js", import.meta.url), "utf8")
const validPreference = (choice = "allow") => `${choice}.v1.${Date.now()}`
const preferenceLifetime = 180 * 24 * 60 * 60 * 1000

function createTracker({ href = "https://lawrelay.be/en?token=private#section", referrer = "", dnt = false, gpc = false, preference, notice } = {}) {
  const listeners = {}
  const pageviews = []
  let script
  const cookies = new Map()
  if (preference) cookies.set("lawrelay_statistics", preference)
  if (notice) cookies.set("lawrelay_cookie_notice", notice)
  const body = { dataset: { lawrelayAnalyticsWebsiteId: "website-id" } }
  const status = { hidden: true }
  const actions = { hidden: true }
  const allowButton = { focus: () => { allowButton.focused = true } }
  const panel = {
    dataset: { analyticsPrivacySignalMessage: "Browser preference keeps statistics off." },
    hidden: false,
    querySelector: (selector) => selector.includes("status") ? status : selector.includes("actions") ? actions : allowButton
  }
  const document = {
    body,
    referrer,
    addEventListener: (name, handler) => { listeners[name] = handler },
    createElement: () => ({ dataset: {} }),
    head: { append: (element) => { script = element } },
    querySelector: (selector) => selector.includes("analytics-preference-panel") ? panel : null
  }
  Object.defineProperty(document, "cookie", {
    get: () => [...cookies].map(([name, value]) => `${name}=${value}`).join("; "),
    set: (value) => {
      const pair = value.split(";")[0]
      const separator = pair.indexOf("=")
      cookies.set(pair.slice(0, separator), pair.slice(separator + 1))
    }
  })
  const window = {
    location: { href, protocol: new URL(href).protocol },
    doNotTrack: dnt ? "1" : "0",
    umami: {
      track: (callback) => pageviews.push(callback({
        website: "website-id",
        hostname: "lawrelay.be",
        language: "en-BE",
        screen: "1440x900",
        title: "Private user name",
        url: "/unsafe?secret",
        referrer: "https://unsafe.example/path?secret",
        tag: "private-tag",
        id: "private-session"
      }))
    }
  }
  const navigator = { doNotTrack: dnt ? "1" : "0", globalPrivacyControl: gpc }
  const sandbox = {
    URL,
    document,
    navigator,
    window
  }

  vm.runInNewContext(trackerSource, sandbox, { filename: "analytics.js" })

  return {
    body,
    emitTurboLoad: () => listeners["turbo:load"](),
    pageviews,
    panel,
    actions,
    script: () => script,
    cookie: (name = "lawrelay_statistics") => cookies.has(name) ? `${name}=${cookies.get(name)}` : "",
    expirePreference: () => { cookies.delete("lawrelay_statistics") },
    setHref: (nextHref) => {
      window.location.href = nextHref
      window.location.protocol = new URL(nextHref).protocol
    },
    setDnt: (value) => {
      navigator.doNotTrack = value ? "1" : "0"
      window.doNotTrack = value ? "1" : "0"
    },
    choose: (choice) => listeners.click({
      target: { closest: (selector) => selector.includes("analytics-preference]") ? { dataset: { analyticsPreference: choice } } : null }
    }),
    openPreferences: () => listeners.click({
      target: { closest: (selector) => selector.includes("analytics-open-preferences") ? {} : null }
    }),
    dismissNotice: () => listeners.click({
      target: { closest: (selector) => selector.includes("analytics-dismiss-banner") ? {} : null }
    })
  }
}

test("loads once and sends a single sanitized public pageview", () => {
  const tracker = createTracker({
    href: "https://lawrelay.be/fr/privacy?email=private#rights",
    referrer: "https://example.org/article?campaign=private#source",
    preference: validPreference()
  })

  tracker.emitTurboLoad()
  assert.equal(tracker.pageviews.length, 0)
  assert.equal(tracker.script().src, "https://analytics.lawrelay.be/script.js")
  assert.equal(tracker.script().dataset.autoTrack, "false")
  assert.equal(tracker.script().dataset.doNotTrack, "true")

  tracker.script().onload()
  assert.equal(JSON.stringify(tracker.pageviews), JSON.stringify([{
    website: "website-id",
    hostname: "lawrelay.be",
    language: "en-BE",
    screen: "1440x900",
    title: "LawRelay",
    url: "/fr/privacy",
    referrer: "https://example.org"
  }]))
})

test("the shared root and unprefixed legal pages are tracked only as sanitized paths", () => {
  for (const [href, path] of [
    ["https://lawrelay.be/?invite=private#top", "/"],
    ["https://lawrelay.be/privacy?token=private#rights", "/privacy"]
  ]) {
    const tracker = createTracker({ href, preference: validPreference() })
    tracker.emitTurboLoad()
    tracker.script().onload()

    assert.equal(tracker.pageviews[0].url, path)
  }
})

test("a private Turbo visit during script loading cancels a stale public pageview", () => {
  const tracker = createTracker({ href: "https://lawrelay.be/nl" })
  tracker.choose("allow")

  tracker.emitTurboLoad()
  tracker.body.dataset = {}
  tracker.setHref("https://lawrelay.be/nl/assignments/42?client=private")
  tracker.emitTurboLoad()
  tracker.script().onload()

  assert.deepEqual(tracker.pageviews, [])
})

test("a privacy signal arriving before script load cancels the pending pageview", () => {
  const tracker = createTracker({ href: "https://lawrelay.be/nl" })
  tracker.choose("allow")

  tracker.emitTurboLoad()
  tracker.setDnt(true)
  tracker.script().onload()

  assert.deepEqual(tracker.pageviews, [])
})

test("DNT and Global Privacy Control override an existing allow preference", () => {
  for (const options of [{ dnt: true }, { gpc: true }]) {
    const tracker = createTracker({ ...options, preference: validPreference() })
    tracker.emitTurboLoad()
    assert.equal(tracker.script(), undefined)
    assert.deepEqual(tracker.pageviews, [])
  }
})

test("non-public paths never load the tracker", () => {
  const tracker = createTracker({ href: "https://lawrelay.be/en/settings?email=private", preference: validPreference() })

  tracker.emitTurboLoad()

  assert.equal(tracker.script(), undefined)
  assert.deepEqual(tracker.pageviews, [])
})

test("private pages keep the preference control without loading analytics", () => {
  const tracker = createTracker({ href: "https://lawrelay.be/en/settings?email=private" })

  tracker.emitTurboLoad()
  assert.equal(tracker.panel.hidden, true)
  tracker.openPreferences()
  assert.equal(tracker.panel.hidden, false)
  tracker.choose("allow")
  assert.match(tracker.cookie(), /^lawrelay_statistics=allow\.v1\.\d+$/)
  assert.equal(tracker.script(), undefined)
  tracker.openPreferences()
  tracker.choose("deny")
  assert.match(tracker.cookie(), /^lawrelay_statistics=deny\.v1\.\d+$/)
  assert.equal(tracker.script(), undefined)
})

test("public statistics start without opt in and dismissing the notice changes no tracking preference", () => {
  const tracker = createTracker({ href: "https://lawrelay.be/de/terms" })

  tracker.emitTurboLoad()
  assert.ok(tracker.script())
  assert.equal(tracker.panel.hidden, false)
  assert.equal(tracker.actions.hidden, true)

  tracker.script().onload()
  assert.equal(tracker.pageviews.length, 1)
  tracker.dismissNotice()
  assert.equal(tracker.cookie(), "")
  assert.match(tracker.cookie("lawrelay_cookie_notice"), /^lawrelay_cookie_notice=seen\.v1\.\d+$/)
  assert.equal(tracker.panel.hidden, true)
  assert.equal(tracker.pageviews.length, 1)
  tracker.openPreferences()
  assert.equal(tracker.actions.hidden, false)
})

test("an existing opt out is preserved and disabling statistics stops an in flight pageview", () => {
  const declined = createTracker({ href: "https://lawrelay.be/en", preference: validPreference("deny") })
  declined.emitTurboLoad()
  assert.match(declined.cookie(), /^lawrelay_statistics=deny\.v1\.\d+$/)
  assert.equal(declined.script(), undefined)
  declined.dismissNotice()
  assert.match(declined.cookie(), /^lawrelay_statistics=deny\.v1\.\d+$/)
  declined.openPreferences()
  declined.choose("allow")
  declined.script().onload()
  assert.equal(declined.pageviews.length, 1)

  const pending = createTracker({ href: "https://lawrelay.be/en" })
  pending.emitTurboLoad()
  pending.openPreferences()
  pending.choose("deny")
  pending.script().onload()
  assert.equal(pending.pageviews.length, 0)

  const tracker = createTracker({ href: "https://lawrelay.be/en", preference: validPreference() })
  tracker.emitTurboLoad()
  tracker.script().onload()
  assert.equal(tracker.panel.hidden, true)
  tracker.openPreferences()
  assert.equal(tracker.panel.hidden, false)
  tracker.choose("deny")
  tracker.emitTurboLoad()
  assert.equal(tracker.pageviews.length, 1)

  const expired = createTracker({ href: "https://lawrelay.be/en", preference: `allow.v1.${Date.now() - preferenceLifetime - 1}` })
  expired.emitTurboLoad()
  assert.ok(expired.script())
  assert.equal(expired.panel.hidden, false)
})

test("the informational notice stays dismissed while public statistics keep working", () => {
  const tracker = createTracker({ notice: `seen.v1.${Date.now()}` })
  tracker.emitTurboLoad()
  assert.equal(tracker.panel.hidden, true)
  tracker.script().onload()
  assert.equal(tracker.pageviews.length, 1)
})

test("malformed and future-dated preference cookies are ignored", () => {
  for (const preference of ["%E0%A4%A", `allow.v1.${Date.now() + 60_000}`]) {
    const tracker = createTracker({ href: "https://lawrelay.be/en", preference })
    tracker.emitTurboLoad()
    assert.ok(tracker.script())
    assert.equal(tracker.panel.hidden, false)
  }
})
