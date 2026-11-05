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
  const choiceButtons = ["deny", "allow"].map((choice) => ({
    dataset: { analyticsPreference: choice },
    attributes: {},
    setAttribute(name, value) { this.attributes[name] = value },
    focus() { this.focused = true }
  }))
  const panel = {
    dataset: { analyticsPrivacySignalMessage: "Browser preference keeps statistics off." },
    hidden: false,
    querySelector: (selector) => selector.includes("status") ? status : selector.includes("actions") ? actions : choiceButtons.find((button) => button.attributes["aria-pressed"] === "true"),
    querySelectorAll: () => choiceButtons
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
    emitBeforeVisit: () => listeners["turbo:before-visit"](),
    pageviews,
    events: () => pageviews.filter((payload) => payload.name),
    panel,
    actions,
    choiceButtons,
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
    setGpc: (value) => { navigator.globalPrivacyControl = value },
    failTracking: () => { window.umami.track = () => { throw new Error("Tracking unavailable") } },
    rejectTracking: () => { window.umami.track = () => Promise.reject(new Error("Tracking unavailable")) },
    clickProduct: (product, { type = "click", button = type === "auxclick" ? 1 : 0, detail = 1, nested = true, inHeader = true, prevented = false } = {}) => {
      const header = {}
      const link = {
        dataset: { lawrelayProduct: product },
        href: "https://product.example/private?email=private#secret",
        textContent: "Private link text",
        target: "_blank",
        closest: (selector) => selector === ".product-bar" ? (inHeader ? header : null) : selector === "a[data-lawrelay-product]" ? link : null
      }
      const target = nested ? { closest: (selector) => selector === "a[data-lawrelay-product]" ? link : null } : link
      const event = {
        type, button, detail, target, defaultPrevented: prevented,
        preventDefault() { throw new Error("Product navigation must remain native") },
        stopPropagation() { throw new Error("Product navigation must remain native") }
      }
      listeners[type](event)
      return link
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

test("the preference buttons show the current effective setting and refresh after a choice", () => {
  const tracker = createTracker()
  const [off, on] = tracker.choiceButtons

  tracker.emitTurboLoad()
  tracker.openPreferences()
  assert.equal(on.attributes["aria-pressed"], "true")
  assert.equal(off.attributes["aria-pressed"], "false")
  assert.equal(on.focused, true)

  tracker.choose("deny")
  assert.equal(off.attributes["aria-pressed"], "true")
  assert.equal(on.attributes["aria-pressed"], "false")
  tracker.openPreferences()
  assert.equal(off.focused, true)
  tracker.emitTurboLoad()
  tracker.openPreferences()
  assert.equal(off.attributes["aria-pressed"], "true")

  tracker.choose("allow")
  assert.equal(on.attributes["aria-pressed"], "true")
  assert.equal(off.attributes["aria-pressed"], "false")
})

test("privacy signals highlight Off even when the stored choice permits statistics", () => {
  for (const options of [{ dnt: true }, { gpc: true }]) {
    const tracker = createTracker({ ...options, preference: validPreference("allow") })
    tracker.emitTurboLoad()
    tracker.openPreferences()
    assert.equal(tracker.choiceButtons[0].attributes["aria-pressed"], "true")
    assert.equal(tracker.choiceButtons[1].attributes["aria-pressed"], "false")
    tracker.choose("allow")
    assert.equal(tracker.choiceButtons[0].attributes["aria-pressed"], "true")
    assert.equal(tracker.script(), undefined)
  }
})

test("malformed and future-dated preference cookies are ignored", () => {
  for (const preference of ["%E0%A4%A", `allow.v1.${Date.now() + 60_000}`]) {
    const tracker = createTracker({ href: "https://lawrelay.be/en", preference })
    tracker.emitTurboLoad()
    assert.ok(tracker.script())
    assert.equal(tracker.panel.hidden, false)
  }
})

test("both header products send fixed event names and sanitized public metadata in every locale", () => {
  for (const locale of ["nl", "fr", "de", "en"]) {
    const tracker = createTracker({
      href: `https://lawrelay.be/${locale}?email=private#account`,
      referrer: "https://example.org/private/path?token=private"
    })
    tracker.emitTurboLoad()
    tracker.script().onload()

    const wetwijzer = tracker.clickProduct("wetwijzer")
    const praxis = tracker.clickProduct("praxis", { nested: false })

    assert.equal(JSON.stringify(tracker.events()), JSON.stringify([
      {
        website: "website-id", hostname: "lawrelay.be", language: "en-BE", screen: "1440x900",
        title: "LawRelay", url: `/${locale}`, referrer: "https://example.org", name: "header_wetwijzer_click"
      },
      {
        website: "website-id", hostname: "lawrelay.be", language: "en-BE", screen: "1440x900",
        title: "LawRelay", url: `/${locale}`, referrer: "https://example.org", name: "header_praxis_click"
      }
    ]))
    assert.equal(wetwijzer.target, "_blank")
    assert.equal(praxis.href, "https://product.example/private?email=private#secret")
    assert.doesNotMatch(JSON.stringify(tracker.events()), /private|secret|product\.example/)
  }
})

test("header clicks preserve normal, keyboard and middle-button navigation without counting other buttons", () => {
  const tracker = createTracker()
  tracker.emitTurboLoad()
  tracker.script().onload()

  tracker.clickProduct("wetwijzer", { nested: false })
  tracker.clickProduct("praxis", { type: "click", button: 0, detail: 0 })
  tracker.clickProduct("wetwijzer", { type: "auxclick", button: 1 })
  tracker.clickProduct("praxis", { type: "auxclick", button: 2 })
  tracker.clickProduct("praxis", { type: "click", button: 1 })
  tracker.clickProduct("praxis", { prevented: true })

  assert.deepEqual(tracker.events().map(({ name }) => name), ["header_wetwijzer_click", "header_praxis_click", "header_wetwijzer_click"])
})

test("only the allowlisted header links are counted", () => {
  const tracker = createTracker()
  tracker.emitTurboLoad()
  tracker.script().onload()

  for (const product of ["unknown", "toString", "__proto__", "header_praxis_click", "wetwijzer?email=private"]) {
    tracker.clickProduct(product)
  }
  tracker.clickProduct("wetwijzer", { inHeader: false })
  assert.deepEqual(tracker.events(), [])
})

test("clicks during tracker loading are bounded and flush once on the same page", () => {
  const tracker = createTracker({ href: "https://lawrelay.be/nl?secret=private" })
  tracker.emitTurboLoad()
  for (let index = 0; index < 12; index++) tracker.clickProduct(index % 2 ? "praxis" : "wetwijzer")
  assert.equal(tracker.pageviews.length, 0)

  tracker.script().onload()
  assert.equal(tracker.pageviews.filter((payload) => !payload.name).length, 1)
  assert.equal(tracker.events().length, 10)
  tracker.script().onload()
  assert.equal(tracker.events().length, 10)
})

test("opt out and browser privacy signals block product events and discard pending clicks", () => {
  for (const options of [{ preference: validPreference("deny") }, { dnt: true }, { gpc: true }]) {
    const tracker = createTracker(options)
    tracker.emitTurboLoad()
    tracker.clickProduct("wetwijzer")
    tracker.clickProduct("praxis", { type: "auxclick" })
    assert.equal(tracker.script(), undefined)
    assert.deepEqual(tracker.events(), [])
  }

  for (const disable of [
    (tracker) => tracker.choose("deny"),
    (tracker) => tracker.setDnt(true),
    (tracker) => tracker.setGpc(true)
  ]) {
    const tracker = createTracker()
    tracker.emitTurboLoad()
    tracker.clickProduct("wetwijzer")
    disable(tracker)
    tracker.script().onload()
    assert.deepEqual(tracker.pageviews, [])
    tracker.clickProduct("praxis")
    assert.deepEqual(tracker.events(), [])
  }
})

test("Turbo navigation, a different website and a private page prevent stale click delivery", () => {
  for (const transition of [
    (tracker) => { tracker.emitBeforeVisit() },
    (tracker) => { tracker.setHref("https://lawrelay.be/fr"); tracker.emitTurboLoad() },
    (tracker) => { tracker.body.dataset.lawrelayAnalyticsWebsiteId = "another-website" },
    (tracker) => { tracker.body.dataset = {}; tracker.setHref("https://lawrelay.be/en/settings?email=private"); tracker.emitTurboLoad() },
    (tracker) => { tracker.body.dataset = {} }
  ]) {
    const tracker = createTracker()
    tracker.emitTurboLoad()
    tracker.clickProduct("wetwijzer")
    transition(tracker)
    tracker.script().onload()
    assert.deepEqual(tracker.events(), [])
  }

  const tracker = createTracker()
  tracker.emitTurboLoad()
  tracker.script().onload()
  tracker.emitBeforeVisit()
  tracker.clickProduct("praxis")
  tracker.body.dataset = {}
  tracker.setHref("https://lawrelay.be/en/assignments/42?client=private")
  tracker.emitTurboLoad()
  tracker.clickProduct("wetwijzer")
  assert.deepEqual(tracker.events(), [])
})

test("private paths never send product clicks even when a stale tracker is loaded", () => {
  const tracker = createTracker()
  tracker.emitTurboLoad()
  tracker.script().onload()
  for (const path of ["session/new", "registration/new", "settings", "assignments/42", "dashboard", "admin/users"]) {
    tracker.setHref(`https://lawrelay.be/en/${path}?private=secret`)
    tracker.clickProduct("wetwijzer")
    tracker.clickProduct("praxis")
  }
  assert.deepEqual(tracker.events(), [])
})

test("tracker failures discard pending events and never interrupt product links", async () => {
  const failedLoad = createTracker()
  failedLoad.emitTurboLoad()
  failedLoad.clickProduct("wetwijzer")
  failedLoad.script().onerror()
  failedLoad.script().onload()
  assert.deepEqual(failedLoad.events(), [])

  const tracker = createTracker()
  tracker.emitTurboLoad()
  tracker.script().onload()
  tracker.failTracking()
  assert.doesNotThrow(() => tracker.clickProduct("wetwijzer"))
  tracker.rejectTracking()
  assert.doesNotThrow(() => tracker.clickProduct("praxis"))
  await Promise.resolve()
})
