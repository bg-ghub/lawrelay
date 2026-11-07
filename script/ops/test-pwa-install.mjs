import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import vm from "node:vm"

const source = readFileSync(new URL("../../app/javascript/pwa.js", import.meta.url), "utf8")
const dismissalKey = "lawrelay_pwa_install_dismissed_at_v1"
const lifetime = 30 * 24 * 60 * 60 * 1000
const tick = () => new Promise((resolve) => setImmediate(resolve))

function createBrowser({
  userAgent = "Chrome/156.0", platform = "Win32", touchPoints = 0,
  standalone = false, iosStandalone = false, secure = true,
  eligible = true, stored, storageFails = false, cookieVisible = false,
  readyState = "complete", serviceWorkerFails = false, workerUrl = "/service-worker.js"
} = {}) {
  const handlers = { window: {}, document: {} }
  const register = (scope, name, callback) => (handlers[scope][name] ||= []).push(callback)
  const emit = (scope, name, event = {}) => handlers[scope][name]?.forEach((handler) => handler(event))
  const storage = new Map(stored === undefined ? [] : [[dismissalKey, stored]])
  const registrations = []
  let now = 1_800_000_000_000
  let currentEligible = eligible
  let displayedStandalone = standalone
  let titleLocale = "en"
  const makePanel = () => {
    const modes = ["native", "ios", "safari", "android", "manual"].map((mode) => ({ dataset: { pwaCopy: mode }, hidden: true, locale: titleLocale }))
    const install = { hidden: true, focus() { this.focused = true } }
    const dismiss = { focus() { this.focused = true } }
    const styles = {}
    return {
      hidden: true, dataset: { serviceWorkerUrl: workerUrl }, modes, install, dismiss, styles,
      style: { setProperty: (name, value) => { styles[name] = value } },
      querySelector: (selector) => selector === "[data-pwa-install]" ? install : dismiss,
      querySelectorAll: () => modes
    }
  }
  let panel = makePanel()
  const footer = { hidden: false, focus() { this.focused = true } }
  const privacyPanel = { hidden: !cookieVisible, height: 130, getBoundingClientRect() { return { height: this.height } } }
  const media = { get matches() { return displayedStandalone }, addEventListener: (name, callback) => register("window", "media:" + name, callback) }
  const location = new URL("https://lawrelay.be/en")
  const navigator = {
    userAgent, platform, maxTouchPoints: touchPoints, standalone: iosStandalone,
    serviceWorker: { register: (url, options) => {
      registrations.push({ url, options })
      return serviceWorkerFails ? Promise.reject(new Error("Unavailable")) : Promise.resolve({})
    } }
  }
  const window = {
    location, isSecureContext: secure, matchMedia: () => media,
    addEventListener: (name, callback) => register("window", name, callback),
    localStorage: {
      getItem: (key) => { if (storageFails) throw new Error("Storage denied"); return storage.get(key) ?? null },
      setItem: (key, value) => { if (storageFails) throw new Error("Storage denied"); storage.set(key, value) },
      removeItem: (key) => { if (storageFails) throw new Error("Storage denied"); storage.delete(key) }
    }
  }
  const document = {
    readyState,
    addEventListener: (name, callback) => register("document", name, callback),
    querySelector: (selector) => {
      if (selector === "[data-analytics-preference-panel]") return privacyPanel
      if (!currentEligible) return null
      return selector === '[rel="manifest"]' || selector === 'link[rel="manifest"]' ? { href: "https://lawrelay.be/en/manifest.webmanifest" } : panel
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
    beforeCache: () => emit("document", "turbo:before-cache"),
    click: (hook) => emit("document", "click", { target: { closest: (selector) => selector === `[${hook}]` ? (hook === "data-pwa-open-install" ? footer : {}) : null } }),
    escape: (defaultPrevented = false) => emit("document", "keydown", { key: "Escape", defaultPrevented }),
    setEligible: (value) => { currentEligible = value },
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

test("dismissal lasts30days and explicit footer installation remains available", () => {
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

test("storage denial preserves in-memory dismissal across Turbo visits", () => {
  const browser = createBrowser({ storageFails: true })
  browser.nativeEvent()
  browser.click("data-pwa-dismiss")
  browser.replacePanel()
  browser.turboLoad()
  assert.equal(browser.panel().hidden, true)
  browser.advance(lifetime)
  browser.turboLoad()
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

  for (const failure of [{ throws: true }, { rejects: true, userChoice: new Promise(() => {}) }]) {
    const browser = createBrowser()
    browser.nativeEvent(failure)
    browser.click("data-pwa-install")
    await tick()
    assert.equal(browser.panel().hidden, false)
    assert.equal(browser.visibleMode(), "manual")
    assert.equal(browser.panel().install.hidden, true)
  }
})

test("iPhone and iPad Safari show manual guidance without a fake native button", () => {
  for (const options of [
    { userAgent: "iPhone AppleWebKit Safari" },
    { userAgent: "Macintosh AppleWebKit Safari", platform: "MacIntel", touchPoints: 5 }
  ]) {
    const browser = createBrowser(options)
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
  for (const options of [{ eligible: false }, { secure: false }]) {
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
})

test("Turbo renders retain an unused native prompt and use the new locale without rewiring", () => {
  const browser = createBrowser()
  const prompt = browser.nativeEvent()
  browser.beforeCache()
  assert.equal(browser.panel().hidden, true)
  browser.replacePanel("fr")
  browser.turboLoad()
  assert.equal(browser.panel().hidden, false)
  assert.equal(browser.panel().modes.find((item) => !item.hidden).locale, "fr")
  browser.click("data-pwa-install")
  assert.equal(prompt.calls, 1)
  assert.equal(browser.handlers.document.click.length, 1)
})

test("a pending prompt cannot open on a page without the PWA markup", () => {
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
  assert.equal(browser.panel().hidden, false)
})

test("cookie information takes priority and explicit install instructions do not overlap it", () => {
  const browser = createBrowser({ cookieVisible: true })
  browser.nativeEvent()
  assert.equal(browser.panel().hidden, true)
  browser.privacyPanel.hidden = true
  browser.click("other-action")
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
