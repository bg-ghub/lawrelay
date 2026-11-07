import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import vm from "node:vm"

const source = readFileSync(new URL("../../app/javascript/pwa.js", import.meta.url), "utf8")
const dismissalKey = "lawrelay_pwa_install_dismissed_at_v2"
const legacyDismissalKey = "lawrelay_pwa_install_dismissed_at_v1"
const lifetime = 30 * 24 * 60 * 60 * 1000
const tick = () => new Promise((resolve) => setTimeout(resolve, 0))

function createBrowser({
  userAgent = "Chrome/156.0", platform = "Win32", touchPoints = 0,
  standalone = false, iosStandalone = false, secure = true,
  eligible = true, stored, legacyStored, storageFails = false, cookieVisible = false,
  readyState = "complete", serviceWorkerFails = false, serviceWorkerThrows = false, workerUrl = "/service-worker.js",
  bannerPresent = true, manifestPresent = true
} = {}) {
  const handlers = { window: {}, document: {} }
  const register = (scope, name, callback) => (handlers[scope][name] ||= []).push(callback)
  const emit = (scope, name, event = {}) => handlers[scope][name]?.forEach((handler) => handler(event))
  const emitWithMicrotasks = async (scope, name, event = {}) => {
    for (const handler of handlers[scope][name] || []) {
      handler(event)
      await Promise.resolve()
    }
  }
  const storage = new Map(stored === undefined ? [] : [[dismissalKey, stored]])
  if (legacyStored !== undefined) storage.set(legacyDismissalKey, legacyStored)
  const registrations = []
  let now = 1_800_000_000_000
  let currentEligible = eligible
  let currentBannerPresent = bannerPresent
  let currentManifestPresent = manifestPresent
  let displayedStandalone = standalone
  let titleLocale = "en"
  let workerFailure = serviceWorkerThrows ? "throw" : serviceWorkerFails ? "reject" : null
  const makePanel = () => {
    const modes = ["native", "ios", "safari", "android", "manual"].map((mode) => ({ dataset: { pwaCopy: mode }, hidden: true, locale: titleLocale }))
    const install = { hidden: true, focus() { this.focused = true; document.activeElement = this } }
    const dismiss = { focus() { this.focused = true; document.activeElement = this } }
    const styles = {}
    return {
      hidden: true, dataset: { serviceWorkerUrl: workerUrl }, modes, install, dismiss, styles,
      contains: (element) => element === install || element === dismiss,
      style: { setProperty: (name, value) => { styles[name] = value } },
      querySelector: (selector) => selector === "[data-pwa-install]" ? install : dismiss,
      querySelectorAll: () => modes
    }
  }
  let panel = makePanel()
  const footer = { hidden: false, focus() { this.focused = true; document.activeElement = this } }
  const privacyPanel = { hidden: !cookieVisible, height: 130, getBoundingClientRect() { return { height: this.height } } }
  const media = { get matches() { return displayedStandalone }, addEventListener: (name, callback) => register("window", "media:" + name, callback) }
  const location = new URL("https://lawrelay.be/en")
  const navigator = {
    userAgent, platform, maxTouchPoints: touchPoints, standalone: iosStandalone,
    serviceWorker: { register: (url, options) => {
      registrations.push({ url, options })
      if (workerFailure === "throw") throw new Error("Unavailable")
      return workerFailure === "reject" ? Promise.reject(new Error("Unavailable")) : Promise.resolve({})
    } }
  }
  const window = {
    location, isSecureContext: secure, matchMedia: () => media,
    setTimeout: (callback, delay) => setTimeout(callback, delay),
    addEventListener: (name, callback) => register("window", name, callback),
    localStorage: {
      getItem: (key) => { if (storageFails) throw new Error("Storage denied"); return storage.get(key) ?? null },
      setItem: (key, value) => { if (storageFails) throw new Error("Storage denied"); storage.set(key, value) },
      removeItem: (key) => { if (storageFails) throw new Error("Storage denied"); storage.delete(key) }
    }
  }
  const document = {
    readyState, activeElement: null, body: {},
    addEventListener: (name, callback) => register("document", name, callback),
    querySelector: (selector) => {
      if (selector === "[data-analytics-preference-panel]") return privacyPanel
      if (!currentEligible) return null
      if (selector === 'link[rel="manifest"]') return currentManifestPresent ? { href: "https://lawrelay.be/en/manifest.webmanifest" } : null
      if (selector === "[data-pwa-install-banner]") return currentBannerPresent ? panel : null
      if (selector === "[data-pwa-open-install]") return footer
      return null
    },
    querySelectorAll: () => currentEligible ? [footer] : []
  }
  vm.runInNewContext(source, { window, document, navigator, URL, Promise, Date: { now: () => now } }, { filename: "pwa.js" })

  return {
    handlers, registrations, storage, privacyPanel, footer,
    panel: () => panel,
    visibleMode: () => panel.modes.find((mode) => !mode.hidden)?.dataset.pwaCopy,
    emitWindow: (name, event) => emit("window", name, event),
    turboLoad: () => emit("document", "turbo:load"),
    turboLoadWithMicrotasks: () => emitWithMicrotasks("document", "turbo:load"),
    beforeCache: () => emit("document", "turbo:before-cache"),
    click: (hook) => emit("document", "click", { target: { closest: (selector) => selector === `[${hook}]` ? (hook === "data-pwa-open-install" ? footer : {}) : null } }),
    clickWithMicrotasks: (hook) => emitWithMicrotasks("document", "click", { target: { closest: (selector) => selector === `[${hook}]` ? (hook === "data-pwa-open-install" ? footer : {}) : null } }),
    escape: (defaultPrevented = false) => emit("document", "keydown", { key: "Escape", defaultPrevented }),
    setEligible: (value) => { currentEligible = value },
    setBannerPresent: (value) => { currentBannerPresent = value },
    setManifestPresent: (value) => { currentManifestPresent = value },
    setFocusedElement: (element) => { document.activeElement = element },
    setWorkerFailure: (value) => { workerFailure = value },
    laterDocumentListener: (name, listener) => register("document", name, listener),
    setReadyState: (value) => { document.readyState = value },
    setStandalone: (value) => { displayedStandalone = value; emit("window", "media:change") },
    advance: (milliseconds) => { now += milliseconds },
    now: () => now,
    replacePanel: (locale = "fr") => { titleLocale = locale; panel = makePanel() },
    nativeEvent: ({ outcome = "accepted", throws = false, rejects = false, userChoice } = {}) => {
      const prompt = {
        prevented: false, calls: 0,
        preventDefault() { this.prevented = true },
        prompt() { this.calls++; if (throws) throw new Error("Prompt unavailable"); return rejects ? Promise.reject(new Error("Prompt unavailable")) : Promise.resolve() },
        userChoice: userChoice || Promise.resolve({ outcome })
      }
      emit("window", "beforeinstallprompt", prompt)
      return prompt
    }
  }
}

test("registers one same-origin root worker without cache and never prompts on load", async () => {
  const browser = createBrowser()
  assert.equal(browser.registrations.length, 1)
  assert.equal(browser.registrations[0].url, "https://lawrelay.be/service-worker.js")
  assert.equal(JSON.stringify(browser.registrations[0].options), JSON.stringify({ scope: "/", updateViaCache: "none" }))
  assert.equal(browser.panel().hidden, true)
  await tick()
  for (let index = 0; index < 5; index++) browser.turboLoad()
  browser.emitWindow("load")
  assert.equal(browser.registrations.length, 1)
  assert.equal(browser.handlers.document.click.length, 1)
  assert.equal(browser.handlers.window.beforeinstallprompt.length, 1)
})

test("native installation starts only synchronously from the install button", async () => {
  const browser = createBrowser()
  const prompt = browser.nativeEvent()
  assert.equal(prompt.prevented, true)
  assert.equal(prompt.calls, 0)
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.panel().install.hidden, false)
  assert.equal(browser.visibleMode(), "native")
  assert.equal(browser.panel().install.focused, undefined, "automatic banner must not take focus")
  browser.click("data-pwa-install")
  assert.equal(prompt.calls, 1, "prompt() must run before this click handler returns")
  assert.equal(browser.panel().hidden, true)
  await tick()
  assert.equal(browser.footer.hidden, true)
  assert.equal(browser.storage.has(dismissalKey), false)
})

test("dismissal lasts30days and explicit footer installation remains available", async () => {
  const browser = createBrowser()
  const prompt = browser.nativeEvent()
  browser.click("data-pwa-dismiss")
  assert.equal(browser.storage.get(dismissalKey), String(browser.now()))
  browser.turboLoad()
  assert.equal(browser.panel().hidden, true)
  browser.click("data-pwa-open-install")
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.panel().install.focused, true)
  assert.equal(prompt.calls, 0)
  browser.click("data-pwa-dismiss")
  assert.equal(browser.footer.focused, true, "closing an explicitly opened panel restores footer focus")
  browser.advance(lifetime - 1)
  browser.turboLoad()
  assert.equal(browser.panel().hidden, true)
  browser.advance(1)
  browser.turboLoad()
  await tick()
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.storage.has(dismissalKey), false)
})

test("malformed expired fractional and future timestamps cannot suppress the prompt", () => {
  for (const value of ["garbage", "Infinity", "0", "1800000000000.5", "1800000000001", String(1_800_000_000_000 - lifetime)]) {
    const browser = createBrowser({ stored: value })
    browser.nativeEvent()
    assert.equal(browser.panel().hidden, false, value)
    assert.equal(browser.storage.has(dismissalKey), false, value)
  }
})

test("storage denial preserves in-memory dismissal across Turbo visits", async () => {
  const browser = createBrowser({ storageFails: true })
  browser.nativeEvent()
  browser.click("data-pwa-dismiss")
  browser.replacePanel()
  browser.turboLoad()
  assert.equal(browser.panel().hidden, true)
  browser.advance(lifetime)
  browser.turboLoad()
  await tick()
  assert.equal(browser.panel().hidden, false)
})

test("appinstalled does not strand an uninstalled app behind a dismissal", async () => {
  const browser = createBrowser()
  browser.nativeEvent()
  browser.click("data-pwa-dismiss")
  assert.equal(browser.storage.has(dismissalKey), true)
  browser.emitWindow("appinstalled")
  assert.equal(browser.panel().hidden, true)
  assert.equal(browser.footer.hidden, true)
  assert.equal(browser.storage.has(dismissalKey), false)
  browser.nativeEvent()
  assert.equal(browser.panel().hidden, false, "a new installability event permits reinstalling")
  assert.equal(browser.footer.hidden, false)
  await tick()
})

test("native dismissal is remembered but a failed native prompt offers manual instructions", async () => {
  const declined = createBrowser()
  declined.nativeEvent({ outcome: "dismissed" })
  declined.click("data-pwa-install")
  await tick()
  assert.equal(declined.storage.has(dismissalKey), true)
  assert.equal(declined.panel().hidden, true)

  for (const failure of [() => ({ throws: true }), () => ({ rejects: true }), () => ({ userChoice: Promise.reject(new Error("Choice unavailable")) })]) {
    const browser = createBrowser()
    browser.nativeEvent(failure())
    browser.click("data-pwa-install")
    await tick()
    assert.equal(browser.panel().hidden, false)
    assert.equal(browser.visibleMode(), "manual")
    assert.equal(browser.panel().install.hidden, true)
    assert.equal(browser.panel().dismiss.focused, true)
    assert.equal(browser.storage.has(dismissalKey), false)
  }
})

test("iPhone and iPad Safari show manual guidance without a fake native button", async () => {
  for (const options of [
    { userAgent: "iPhone AppleWebKit Safari" },
    { userAgent: "Macintosh AppleWebKit Safari", platform: "MacIntel", touchPoints: 5 }
  ]) {
    const browser = createBrowser(options)
    await tick()
    assert.equal(browser.panel().hidden, false)
    assert.equal(browser.visibleMode(), "ios")
    assert.equal(browser.panel().install.hidden, true)
    assert.equal(browser.panel().dismiss.focused, undefined)
  }
  const chromeIos = createBrowser({ userAgent: "iPhone AppleWebKit CriOS Safari" })
  assert.equal(chromeIos.panel().hidden, true)
  chromeIos.click("data-pwa-open-install")
  assert.equal(chromeIos.visibleMode(), "ios")
})

test("standalone apps never show install actions and still receive worker updates", () => {
  for (const options of [{ standalone: true }, { iosStandalone: true }]) {
    const browser = createBrowser(options)
    assert.equal(browser.registrations.length, 1)
    browser.nativeEvent()
    browser.click("data-pwa-open-install")
    assert.equal(browser.panel().hidden, true)
    assert.equal(browser.footer.hidden, true)
  }
  const browser = createBrowser()
  browser.nativeEvent()
  browser.setStandalone(true)
  assert.equal(browser.panel().hidden, true)
})

test("unsupported browsers get instructions only on explicit request", () => {
  for (const [options, expected] of [
    [{}, "manual"],
    [{ userAgent: "Macintosh Version/26 Safari", platform: "MacIntel" }, "safari"],
    [{ userAgent: "Android Firefox/150" }, "android"]
  ]) {
    const browser = createBrowser(options)
    assert.equal(browser.panel().hidden, true)
    browser.click("data-pwa-open-install")
    assert.equal(browser.visibleMode(), expected)
    assert.equal(browser.panel().install.hidden, true)
    assert.equal(browser.panel().dismiss.focused, true)
    browser.escape(true)
    assert.equal(browser.panel().hidden, false, "a dropdown may handle Escape first")
    browser.escape()
    assert.equal(browser.panel().hidden, true)
  }
})

test("admin missing-manifest and insecure contexts never register or capture installation", () => {
  for (const options of [{ eligible: false }, { manifestPresent: false }, { secure: false }]) {
    const browser = createBrowser(options)
    const prompt = browser.nativeEvent()
    browser.turboLoad()
    browser.click("data-pwa-open-install")
    assert.equal(prompt.prevented, false)
    assert.equal(prompt.calls, 0)
    assert.equal(browser.registrations.length, 0)
    assert.equal(browser.panel().hidden, true)
  }
  const foreignWorker = createBrowser({ workerUrl: "https://other.example/service-worker.js" })
  assert.equal(foreignWorker.registrations.length, 0)
  const malformedWorker = createBrowser({ workerUrl: "https://[" })
  assert.equal(malformedWorker.registrations.length, 0)
})

test("Turbo renders retain an unused native prompt and use the new locale without rewiring", async () => {
  const browser = createBrowser()
  const prompt = browser.nativeEvent()
  browser.beforeCache()
  assert.equal(browser.panel().hidden, true)
  browser.replacePanel("fr")
  browser.turboLoad()
  await tick()
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.panel().modes.find((item) => !item.hidden).locale, "fr")
  browser.click("data-pwa-install")
  assert.equal(prompt.calls, 1)
  assert.equal(browser.handlers.document.click.length, 1)
})

test("a pending prompt cannot open on a page without the PWA markup", async () => {
  const browser = createBrowser()
  const prompt = browser.nativeEvent()
  browser.beforeCache()
  browser.setEligible(false)
  browser.click("data-pwa-install")
  browser.turboLoad()
  assert.equal(prompt.calls, 0)
  assert.equal(browser.panel().hidden, true)
  browser.setEligible(true)
  browser.turboLoad()
  await tick()
  assert.equal(browser.panel().hidden, false)
})

test("cookie information takes priority and explicit install instructions do not overlap it", async () => {
  const browser = createBrowser({ cookieVisible: true })
  browser.nativeEvent()
  assert.equal(browser.panel().hidden, true)
  browser.privacyPanel.hidden = true
  browser.click("other-action")
  await tick()
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.panel().styles["--pwa-bottom-offset"], "12px")
  browser.privacyPanel.hidden = false
  browser.click("data-pwa-open-install")
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.panel().styles["--pwa-bottom-offset"], "154px")
  browser.privacyPanel.height = 200
  browser.emitWindow("resize")
  assert.equal(browser.panel().styles["--pwa-bottom-offset"], "224px")
})

test("worker registration waits for load and failure leaves the site usable", async () => {
  const delayed = createBrowser({ readyState: "interactive" })
  delayed.turboLoad()
  assert.equal(delayed.registrations.length, 0)
  delayed.setReadyState("complete")
  delayed.emitWindow("load")
  assert.equal(delayed.registrations.length, 1)

  const failed = createBrowser({ serviceWorkerFails: true })
  await tick()
  failed.nativeEvent()
  assert.equal(failed.panel().hidden, false)
  failed.click("data-pwa-dismiss")
  assert.equal(failed.panel().hidden, true)
})

test("an early installability event is retained until the banner and worker are ready", async () => {
  const browser = createBrowser({ readyState: "loading", bannerPresent: false })
  const prompt = browser.nativeEvent()
  assert.equal(prompt.prevented, true)
  assert.equal(prompt.calls, 0)
  assert.equal(browser.registrations.length, 0)

  browser.setBannerPresent(true)
  browser.setReadyState("complete")
  browser.emitWindow("load")
  await tick()
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.panel().install.hidden, false)
  assert.equal(browser.visibleMode(), "native")
  assert.equal(browser.registrations.length, 1)
  browser.click("data-pwa-install")
  assert.equal(prompt.calls, 1)
})

test("closing footer help does not suppress a later automatic native offer for30days", () => {
  for (const dismiss of [(browser) => browser.click("data-pwa-dismiss"), (browser) => browser.escape()]) {
    const browser = createBrowser()
    browser.click("data-pwa-open-install")
    assert.equal(browser.visibleMode(), "manual")
    assert.equal(browser.panel().install.hidden, true)
    dismiss(browser)
    assert.equal(browser.panel().hidden, true)
    assert.equal(browser.storage.has(dismissalKey), false)
    assert.equal(browser.footer.focused, true)

    const prompt = browser.nativeEvent()
    assert.equal(browser.panel().hidden, false)
    assert.equal(browser.panel().install.hidden, false)
    assert.equal(browser.visibleMode(), "native")
    assert.equal(prompt.calls, 0)
  }
})

test("a fresh legacy help-dismissal timestamp cannot suppress the new automatic offer", async () => {
  const browser = createBrowser({ legacyStored: "1800000000000" })
  browser.nativeEvent()
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.panel().install.hidden, false)
  assert.equal(browser.storage.has(legacyDismissalKey), false)
  assert.equal(browser.storage.has(dismissalKey), false)
  browser.click("data-pwa-dismiss")
  assert.equal(browser.storage.get(dismissalKey), String(browser.now()))
  browser.turboLoad()
  await tick()
  assert.equal(browser.panel().hidden, true, "declines after the patch still last30days")
})

test("a later cookie-panel click listener reveals a queued automatic install offer", async () => {
  const browser = createBrowser({ cookieVisible: true })
  await tick()
  const prompt = browser.nativeEvent()
  browser.laterDocumentListener("click", () => { browser.privacyPanel.hidden = true })
  await browser.clickWithMicrotasks("data-analytics-dismiss-banner")
  assert.equal(browser.panel().hidden, true, "refresh waits for later click handlers")
  await tick()
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.visibleMode(), "native")
  assert.equal(browser.panel().install.hidden, false)
  assert.equal(prompt.calls, 0)
})

test("Turbo readiness respects cookie state changed by a later analytics listener", async () => {
  const browser = createBrowser()
  await tick()
  browser.nativeEvent()
  browser.laterDocumentListener("turbo:load", () => { browser.privacyPanel.hidden = false })
  browser.replacePanel("fr")
  await browser.turboLoadWithMicrotasks()
  await tick()
  assert.equal(browser.panel().hidden, true)
})

test("late prompt failure cannot open help on a later Turbo page or replace a newer offer", async () => {
  for (const navigation of [true, false]) {
    let rejectChoice
    const browser = createBrowser()
    browser.nativeEvent({ userChoice: new Promise((_, reject) => { rejectChoice = reject }) })
    browser.click("data-pwa-install")
    await tick()
    if (navigation) {
      browser.beforeCache()
      browser.replacePanel("fr")
      browser.turboLoad()
    } else {
      browser.nativeEvent()
    }
    rejectChoice(new Error("Old choice unavailable"))
    await tick()
    assert.equal(browser.storage.has(dismissalKey), false)
    if (navigation) assert.equal(browser.panel().hidden, true)
    else {
      assert.equal(browser.panel().hidden, false)
      assert.equal(browser.visibleMode(), "native")
      assert.equal(browser.panel().install.hidden, false)
    }
    assert.equal(browser.panel().dismiss.focused, undefined)
  }
})

test("prompt failure gives keyboard guidance without stealing focus from another form", async () => {
  let rejectChoice
  const browser = createBrowser()
  browser.nativeEvent({ userChoice: new Promise((_, reject) => { rejectChoice = reject }) })
  browser.click("data-pwa-install")
  await tick()
  browser.setFocusedElement({ name: "another-form-field" })
  rejectChoice(new Error("Choice unavailable"))
  await tick()
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.visibleMode(), "manual")
  assert.equal(browser.panel().dismiss.focused, undefined)
})

test("a genuine native decline restores footer focus and remembers only that decline", async () => {
  const browser = createBrowser()
  browser.nativeEvent({ outcome: "dismissed" })
  browser.click("data-pwa-install")
  await tick()
  assert.equal(browser.storage.get(dismissalKey), String(browser.now()))
  assert.equal(browser.footer.focused, true)
  assert.equal(browser.panel().hidden, true)
})

test("worker registration can retry after synchronous or asynchronous failure", async () => {
  for (const options of [{ serviceWorkerThrows: true }, { serviceWorkerFails: true }]) {
    const browser = createBrowser(options)
    await tick()
    browser.setWorkerFailure(null)
    browser.turboLoad()
    await tick()
    browser.turboLoad()
    assert.equal(browser.registrations.length, 2)
  }
})
