import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.timeout = null
    this.initialLoad = true
    this.edited = false
    this.syncFromURL()
    this.onRestore = () => {
      this.restoring = true
      this.cancelPending()
      this.stopSubmission()
    }
    this.onLoad = () => {
      if (this.restoring || this.initialLoad && !this.edited) {
        this.syncFromURL()
        if (!this.submission) {
          this.element.removeAttribute("aria-busy")
          const frame = document.getElementById(this.element.dataset.turboFrame)
          frame?.removeAttribute("busy")
          frame?.removeAttribute("aria-busy")
        }
      }
      this.restoring = false
      this.initialLoad = false
    }
    this.onStart = event => {
      if (event.target !== this.element) return
      if (this.restoring) {
        event.detail.formSubmission.stop()
        return
      }
      this.edited = true
      this.submission = event.detail.formSubmission
    }
    this.onEnd = event => {
      if (event.detail.formSubmission === this.submission) this.submission = null
    }
    this.onBeforeVisit = event => {
      if (!this.restoring) return

      const destination = new URL(event.detail.url, window.location.href)
      const current = new URL(window.location.href)
      const board = new URL(this.element.action, current)
      destination.hash = current.hash = ""
      destination.searchParams.sort()
      current.searchParams.sort()
      // A delayed frame promotion must not replace an active Back restoration.
      if (destination.origin === current.origin && destination.pathname === board.pathname && destination.href !== current.href) {
        event.preventDefault()
      }
    }
    window.addEventListener("popstate", this.onRestore)
    document.addEventListener("turbo:load", this.onLoad)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
    this.element.addEventListener("turbo:submit-start", this.onStart)
    this.element.addEventListener("turbo:submit-end", this.onEnd)
  }

  syncFromURL() {
    // Turbo can cache the next typed value under the previous history URL.
    // Reconcile only on connection or restoration, not ordinary frame updates.
    const query = new URLSearchParams(window.location.search)
    for (const field of this.element.elements) {
      if (!["q", "kind", "city", "practice_area"].includes(field.name)) continue

      const value = query.get(field.name) || ""
      if (field.type === "radio") {
        field.checked = field.value === value
      } else {
        field.value = value
        // Refresh an already connected searchable select without submitting.
        if (field.tagName === "SELECT") field.dispatchEvent(new Event("change"))
      }
    }
  }

  cancelPending() { clearTimeout(this.timeout) }

  submit() {
    if (this.restoring) return
    this.edited = true
    this.cancelPending()
    this.element.requestSubmit()
  }

  debounce() {
    if (this.restoring) return
    this.edited = true
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.submit(), 350)
  }

  stopSubmission() {
    this.submission?.stop()
    this.submission = null
  }

  disconnect() {
    this.cancelPending()
    this.stopSubmission()
    window.removeEventListener("popstate", this.onRestore)
    document.removeEventListener("turbo:load", this.onLoad)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    this.element.removeEventListener("turbo:submit-start", this.onStart)
    this.element.removeEventListener("turbo:submit-end", this.onEnd)
  }
}
