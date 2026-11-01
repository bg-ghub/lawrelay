import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["text", "attribution"]
  static values = { url: String, pending: Boolean, unavailable: String }

  connect() {
    this.attempts = 0
    if (this.pendingValue) this.schedule()
  }

  disconnect() {
    clearTimeout(this.timer)
    this.request?.abort()
  }

  schedule() {
    if (!this.element.isConnected) return
    if (this.attempts >= 8) {
      this.textTarget.textContent = this.unavailableValue
      return
    }
    this.timer = setTimeout(() => this.refresh(), 2000)
  }

  async refresh() {
    if (!this.element.isConnected) return
    this.attempts += 1
    this.request = new AbortController()
    const timeout = setTimeout(() => this.request.abort(), 4000)
    try {
      const response = await fetch(this.urlValue, {
        credentials: "same-origin", headers: { Accept: "application/json" }, signal: this.request.signal
      })
      if (!response.ok || response.redirected) throw new Error("Route unavailable")
      const result = await response.json()
      if (result.status === "pending") this.schedule()
      else {
        this.textTarget.textContent = result.text
        if (this.hasAttributionTarget) this.attributionTarget.hidden = result.status !== "ready"
      }
    } catch {
      this.textTarget.textContent = this.unavailableValue
    } finally {
      clearTimeout(timeout)
    }
  }
}
